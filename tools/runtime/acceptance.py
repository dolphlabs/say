from __future__ import annotations

import argparse
import concurrent.futures
import contextlib
import datetime as dt
import hashlib
import http.client
import json
import os
from pathlib import Path
import random
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from urllib.parse import urlsplit, urlunsplit

import psycopg
from psycopg import sql
from psycopg.conninfo import conninfo_to_dict
import redis

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools/oracle"))
from exchange import Exchange


def uid():
    return str(uuid.uuid4())


def database_url(base, name, proxy_port=None):
    parts=urlsplit(base)
    authority=parts.netloc
    if proxy_port is not None:
        authority=authority.rsplit("@",1)[0]+f"@127.0.0.1:{proxy_port}"
    return urlunsplit((parts.scheme,authority,"/"+name,parts.query,parts.fragment))


def wait_for(fn, timeout=25, label="condition"):
    end = time.monotonic() + timeout
    last = None
    while time.monotonic() < end:
        try:
            value = fn()
            if value:
                return value
        except (OSError, psycopg.Error) as error:
            last = error
        time.sleep(0.025)
    raise AssertionError(f"timed out waiting for {label}: {last}")


def port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class Proxy:
    def __init__(self, upstream, protocol):
        self.upstream, self.protocol = upstream, protocol
        self.port = port()
        self.enabled = True
        self.barrier = threading.Event()
        self.release = threading.Event()
        self.commit_pause = False
        self.before_commit_pause = False
        self.frontier_pause = False
        self.redis_drop = False
        self.redis_target = ""
        self.fenced = threading.Event()
        self.stop = False
        self.sockets = []
        self.listener = socket.create_server(("127.0.0.1", self.port))
        self.listener.settimeout(0.2)
        threading.Thread(target=self.accept, daemon=True).start()

    def accept(self):
        while not self.stop:
            try:
                client, _ = self.listener.accept()
            except (OSError, TimeoutError):
                continue
            if not self.enabled:
                client.close()
                continue
            server = socket.create_connection(self.upstream)
            self.sockets.extend((client, server))
            state = dict(economic=False,publish=False,recent=b"")
            threading.Thread(target=self.pipe, args=(client, server, False,state), daemon=True).start()
            threading.Thread(target=self.pipe, args=(server, client, True,state), daemon=True).start()

    def pipe(self, source, target, backend,state):
        buffer = b""
        try:
            while not self.stop:
                data = source.recv(65536)
                if not data:
                    break
                if not backend:
                    state["recent"]=(state["recent"]+data)[-32768:]
                    if self.protocol=="pg" and b"say.transition.v1" in data:
                        state["economic"]=True
                    if self.protocol=="redis" and b"XADD" in state["recent"] and self.redis_target.encode() in state["recent"]:
                        state["publish"]=True
                    if self.protocol=="pg" and self.before_commit_pause and state["economic"] and b"COMMIT\x00" in data:
                        self.before_commit_pause=False
                        self.barrier.set()
                        self.release.wait(30)
                    if self.protocol=="pg" and self.frontier_pause and b"select pg_advisory_xact_lock(73101" in data:
                        self.frontier_pause=False
                        self.barrier.set()
                        self.release.wait(30)
                if backend and self.protocol == "pg":
                    buffer += data
                    while len(buffer) >= 5:
                        size = struct.unpack("!I", buffer[1:5])[0] + 1
                        if len(buffer) < size:
                            break
                        message, buffer = buffer[:size], buffer[size:]
                        if b"SAY_OWNER_FENCED" in message:
                            self.fenced.set()
                        if self.commit_pause and state["economic"] and message == b"C\x00\x00\x00\x0bCOMMIT\x00":
                            self.commit_pause = False
                            self.barrier.set()
                            self.release.wait(30)
                        if message == b"C\x00\x00\x00\x0bCOMMIT\x00":
                            state["economic"]=False
                        target.sendall(message)
                    continue
                if backend and self.protocol == "redis" and self.redis_drop and state["publish"]:
                    self.redis_drop = False
                    self.barrier.set()
                    break
                target.sendall(data)
        except OSError:
            pass
        finally:
            for sock in (source, target):
                with contextlib.suppress(OSError):
                    sock.shutdown(socket.SHUT_RDWR)
                sock.close()

    def outage(self):
        self.enabled = False
        for sock in self.sockets:
            with contextlib.suppress(OSError):
                sock.shutdown(socket.SHUT_RDWR)
                sock.close()
        self.sockets.clear()

    def close(self):
        self.stop = True
        self.release.set()
        self.outage()
        self.listener.close()


class Harness:
    def __init__(self, args):
        self.args = args
        self.name = "say_accept_" + uuid.uuid4().hex[:12]
        self.base = psycopg.connect(args.owner, autocommit=True)
        self.base.execute(sql.SQL("create database {}").format(sql.Identifier(self.name)))
        self.owner_url = database_url(args.owner, self.name)
        self.app_url = database_url(args.app, self.name)
        self.owner = psycopg.connect(self.owner_url, autocommit=True)
        self.processes = []
        self.logs = tempfile.TemporaryDirectory(prefix="say-runtime-logs-")
        self.redis = redis.Redis.from_url(args.redis, decode_responses=True)
        redis_cfg = redis.Redis.from_url(args.redis).connection_pool.connection_kwargs
        self.redis_proxy = Proxy((redis_cfg["host"], redis_cfg["port"]), "redis")
        pg_cfg = conninfo_to_dict(args.app)
        self.pg_proxy = Proxy((pg_cfg.get("host", "127.0.0.1"), int(pg_cfg.get("port", 5432))), "pg")
        env = dict(os.environ, DATABASE_URL=self.owner_url, TZ="UTC")
        subprocess.run(["zokor", "migrate", "migrations"], cwd=ROOT, env=env, check=True,
                       stdout=subprocess.DEVNULL)
        self.creator = uid()
        self.owner.execute("insert into accounts(id,username,status) values(%s,'runtime.creator','ACTIVE')", (self.creator,))
        now = dt.datetime.now(dt.timezone.utc)
        anchor = dt.datetime(2026, 10, 11, 23, tzinfo=dt.timezone.utc)
        ordinal = int((now - anchor).total_seconds() // (14 * 86400)) + 1
        start = anchor + dt.timedelta(days=14 * (ordinal - 1))
        self.season = uid()
        self.owner.execute("insert into seasons(id,ordinal,starts_at,ends_at,status) values(%s,%s,%s,%s,'ACTIVE')",
                           (self.season, ordinal, start, start + dt.timedelta(days=14)))
        self.source = uid()
        self.owner.execute("insert into resolution_sources(id,name,url_pattern,kind,created_by) values(%s,'Runtime fixture','https://example.test/result','json',%s)",
                           (self.source, self.creator))
        for owner in ("system:treasury", "system:fees", "system:issuance"):
            self.owner.execute("insert into wallets(season_id,owner_kind,owner_id,asset_key) values(%s,'system',%s,'SEDI')", (self.season, owner))
        self.results = []

    def fixture(self, op, accounts=(), amount=0, market=""):
        request = dict(op=op, season_id=self.season, accounts=list(accounts), amount=amount, market_id=market)
        completed = subprocess.run([str(ROOT / "bin/runtime-fixture")], cwd=ROOT,
                                   env=dict(os.environ, TEST_APP_DATABASE_URL=self.app_url, TZ="UTC"),
                                   input=json.dumps(request), capture_output=True, text=True, timeout=180)
        assert completed.returncode == 0, completed.stderr + completed.stdout
        return json.loads(completed.stdout)

    def market(self,V=100):
        market = uid()
        minimum=2 if V==200 else 1
        policy = dict(market_id=market, season_id=self.season, V=V, min_price=minimum, max_price=V-minimum,
                      tick=1, max_order_qty=10000, min_order_notional=2)
        self.owner.execute("""insert into markets(id,slug,question,season_id,created_by,status,redemption_units,
            min_price,max_price,tick,fee_units,min_order_notional,category_id,resolution_source_id,
            open_at,close_at,resolve_by,rules,terms_version,terms_hash,rolling_hash)
            values(%s,%s,'Will the runtime preserve every financial invariant?',%s,%s,'OPEN',%s,%s,%s,1,1,2,
            '00000000-0000-4000-a000-000000000101',%s,clock_timestamp()-interval '1 hour',
            clock_timestamp()+interval '1 hour',clock_timestamp()+interval '2 hours',%s::jsonb,1,%s,%s)""",
            (market, market, self.season, self.creator,V,minimum,V-minimum,self.source,
             json.dumps(dict(yes_if="The verified outcome is yes.", no_if="The verified outcome is no.",
                             edge_cases="The approved source determines edge cases.")), "a" * 64, Exchange(policy).state_hash))
        for owner, asset in ((f"system:collateral:{market}", "SEDI"),
                             (f"system:shares:{market}", f"YES:{market}"),
                             (f"system:shares:{market}", f"NO:{market}")):
            self.owner.execute("insert into wallets(season_id,owner_kind,owner_id,asset_key) values(%s,'system',%s,%s)",
                               (self.season, owner, asset))
        return market

    def users(self, count=4, amount=1000000):
        users = []
        for _ in range(count):
            account, token = uid(), uid() + uid()
            self.owner.execute("insert into accounts(id,username,status) values(%s,%s,'ACTIVE')", (account, account))
            self.owner.execute("insert into sessions(account_id,token_hash,expires_at) values(%s,%s,clock_timestamp()+interval '1 day')",
                               (account, hashlib.sha256(token.encode()).digest()))
            users.append((account, token))
        self.fixture("fund", [u[0] for u in users], amount)
        return users

    def start(self, *, proxy_pg=False, reply="300ms", settings=None):
        number = len(self.processes)
        service_port = port()
        log = open(Path(self.logs.name) / f"node-{number}.log", "w+")
        app_url = database_url(self.app_url,self.name,self.pg_proxy.port) if proxy_pg else self.app_url
        env = dict(os.environ, PORT=str(service_port), DATABASE_URL=app_url,
                   REDIS_URL=f"redis://127.0.0.1:{self.redis_proxy.port}", PROFILE="test", EMAIL_PROVIDER="console",
                   OTP_SECRET="runtime-acceptance-secret-0123456789abcdef", TZ="UTC", PG_TIMEOUT="2s",
                   DB_POOL_SIZE="32", EXCHANGE_REPLY_WAIT=reply, EXCHANGE_POLL="10ms", EXCHANGE_PENDING_LIMIT="5000",
                   EXCHANGE_SNAPSHOT_EVERY="2s", EXCHANGE_SNAPSHOT_COMMANDS="1000")
        env.update(settings or {})
        process = subprocess.Popen([str(getattr(self.args,"binary",ROOT/"bin/say"))], cwd=ROOT, env=env, stdout=log, stderr=log)
        node = dict(process=process, port=service_port, log=log)
        self.processes.append(node)
        try:
            wait_for(lambda: process.poll() is None and self.request(node, "GET", "/healthz")[0] == 200,
                     label="service startup")
        except Exception:
            log.seek(0)
            raise AssertionError(log.read())
        return node

    def kill(self, node):
        node["process"].kill()
        node["process"].wait(10)

    def stop_nodes(self):
        for node in self.processes:
            if node["process"].poll() is None:
                self.kill(node)

    def request(self, node, method, path, body=None, user=None, key=None):
        conn = http.client.HTTPConnection("127.0.0.1", node["port"], timeout=10)
        headers = {"Content-Type": "application/json"}
        if user:
            headers["Cookie"] = "say_session=" + user[1]
        if key:
            headers["Idempotency-Key"] = key
        try:
            conn.request(method, path, json.dumps(body) if body is not None else None, headers)
            response = conn.getresponse()
            data = response.read()
            return response.status, json.loads(data) if data else {}, dict(response.getheaders())
        finally:
            conn.close()

    def ready(self, node, market):
        return wait_for(lambda: self.request(node, "GET", f"/v1/markets/{market}/book")[0] == 200,
                        label="ready market")

    def place(self, node, market, user, outcome="YES", side="BUY", price=40, qty=1, key=None, tif="GTC"):
        key = key or uid()
        status, response, _ = self.request(node, "POST", f"/v1/markets/{market}/orders",
                                           dict(outcome=outcome, side=side, price=price, qty=qty, tif=tif), user, key)
        assert status in (200, 202), (status, response)
        return response, key

    def order(self, node, user, order_id, terminal=False):
        def load():
            status, value, _ = self.request(node, "GET", f"/v1/orders/{order_id}", user=user)
            if status == 200 and value["status"] != "ADMITTED":
                if not terminal or value["status"] not in ("OPEN", "PARTIAL"):
                    return value
        return wait_for(load, label="committed order")

    def reconcile(self):
        run = self.fixture("reconcile")
        assert run["ok"], run
        return run

    def differential(self, market):
        V,minimum,maximum,tick,quantity,notional=self.owner.execute("select redemption_units,min_price,max_price,tick,max_order_qty,min_order_notional from markets where id=%s",(market,)).fetchone()
        policy = dict(market_id=market, season_id=self.season, V=V, min_price=minimum, max_price=maximum,
                      tick=tick, max_order_qty=quantity, min_order_notional=notional)
        state = Exchange(policy)
        count=0
        with psycopg.connect(self.owner_url) as conn:
            with conn.cursor(name="runtime_differential") as rows:
                rows.itersize=128
                rows.execute("select resolved_input,transition from market_commands where market_id=%s and state<>'PENDING' order by seq", (market,))
                for command, actual in rows:
                    expected = state.plan(command)
                    state.apply(expected)
                    expected = expected.transition
                    expected["decision"] = expected.pop("result")
                    expected.setdefault("full_state_hash", None)
                    assert actual == expected, (command["seq"], actual, expected)
                    count+=1
        return count

    def record(self, name, fn):
        started = time.monotonic()
        details = fn() or {}
        result = dict(name=name, seconds=round(time.monotonic() - started, 3), **details)
        self.results.append(result)
        print(json.dumps(result), flush=True)

    def close(self):
        self.pg_proxy.release.set()
        for node in self.processes:
            if node["process"].poll() is None:
                self.kill(node)
            node["log"].close()
        self.pg_proxy.close()
        self.redis_proxy.close()
        self.owner.close()
        self.base.execute(sql.SQL("drop database {} with (force)").format(sql.Identifier(self.name)))
        self.base.close()
        self.logs.cleanup()


def financial(h):
    market, users = h.market(), h.users()
    node = h.start()
    h.ready(node, market)
    a, b, c, d = users
    orders = []
    for user, outcome, side, price, qty in ((a,"YES","BUY",40,3),(b,"NO","BUY",60,3),
            (a,"YES","SELL",45,2),(c,"YES","BUY",50,2),(b,"NO","SELL",60,1),
            (d,"NO","BUY",65,1),(b,"NO","SELL",60,1),(c,"YES","SELL",35,1)):
        response, _ = h.place(node, market, user, outcome, side, price, qty)
        orders.append(h.order(node, user, response["order_id"]))
    modes = [r[0] for r in h.owner.execute("select mode from fills where market_id=%s order by execution_seq,fill_index", (market,))]
    assert modes == ["MINT", "TRANSFER_YES", "TRANSFER_NO", "MERGE"], modes
    assert h.request(node,"GET",f"/v1/orders/{orders[0]['order_id']}",user=d)[0] == 404
    h.reconcile()
    count = h.differential(market)
    return dict(commands=count, modes=modes, reconciliation="passed")


def golden(h):
    node=h.processes[-1]
    users=h.users(10,1000000)
    checked=0
    for case in "ABCDEFGHIJ":
        market=h.market(200 if case=="H" else 100)
        h.ready(node,market)
        V=200 if case=="H" else 100
        def place(who,outcome,side,price,qty,tif="GTC"):
            response,_=h.place(node,market,users[who],outcome,side,price,qty,tif=tif)
            return h.order(node,users[who],response["order_id"])
        def inventory(who,outcome,qty,other=9):
            place(who,outcome,"BUY",V//2,qty)
            place(other,"NO" if outcome=="YES" else "YES","BUY",V//2,qty)
        def fills(order):
            return h.owner.execute("select mode,yes_equivalent_price,qty from fills where taker_order_id=%s order by fill_index",(order["order_id"],)).fetchall()
        if case=="A":
            inventory(0,"YES",1)
            place(0,"YES","SELL",60,1)
            order=place(1,"YES","BUY",75,1)
            assert fills(order)==[("TRANSFER_YES",60,1)]
        elif case=="B":
            place(0,"NO","BUY",45,1)
            order=place(1,"YES","BUY",70,1)
            assert fills(order)==[("MINT",55,1)]
        elif case=="C":
            inventory(0,"YES",1,1)
            place(1,"NO","SELL",40,1)
            order=place(0,"YES","SELL",50,1)
            assert fills(order)==[("MERGE",60,1)]
        elif case=="D":
            inventory(0,"NO",2)
            place(1,"NO","BUY",40,2)
            order=place(0,"NO","SELL",35,2)
            assert fills(order)==[("TRANSFER_NO",60,2)]
        elif case=="E":
            inventory(0,"YES",3)
            place(0,"YES","SELL",58,3)
            place(1,"NO","BUY",42,5)
            order=place(2,"YES","BUY",60,6)
            assert fills(order)==[("TRANSFER_YES",58,3),("MINT",58,3)]
        elif case=="F":
            for who,price,qty in ((0,58,80),(1,59,110),(2,61,180)):
                inventory(who,"YES",qty)
                place(who,"YES","SELL",price,qty)
            order=place(3,"YES","BUY",61,250)
            assert fills(order)==[("TRANSFER_YES",58,80),("TRANSFER_YES",59,110),("TRANSFER_YES",61,60)]
        elif case=="G":
            inventory(0,"YES",4)
            maker=place(0,"YES","SELL",58,4)
            order=place(0,"YES","BUY",58,10)
            assert order["filled"]==0 and order["cancelled"]==10 and not order["fee_paid"]
            assert h.order(node,users[0],maker["order_id"])["remaining"]==4
        elif case=="H":
            inventory(0,"YES",3)
            place(0,"YES","SELL",120,3)
            order=place(1,"YES","BUY",120,3)
            assert fills(order)==[("TRANSFER_YES",120,3)]
        elif case=="I":
            inventory(0,"YES",4)
            place(0,"YES","SELL",58,4)
            order=place(1,"YES","BUY",58,10,"IOC")
            assert order["filled"]==4 and order["cancelled"]==6 and order["fee_paid"]
        else:
            inventory(0,"YES",5)
            maker=place(0,"YES","SELL",58,5)
            place(1,"YES","BUY",60,2)
            place(2,"YES","BUY",60,3)
            assert h.owner.execute("select count(*) from ledger_transactions where business_key=%s",("fee:"+maker["order_id"],)).fetchone()[0]==1
            unused=place(3,"YES","BUY",20,1)
            status,_,_=h.request(node,"DELETE",f"/v1/orders/{unused['order_id']}",user=users[3])
            assert status in (200,202)
            h.order(node,users[3],unused["order_id"],terminal=True)
            assert h.owner.execute("select count(*) from ledger_transactions where business_key=%s",("fee:"+unused["order_id"],)).fetchone()[0]==0
        checked+=h.differential(market)
    h.reconcile()
    return dict(cases=list("ABCDEFGHIJ"),commands=checked,reconciliation="passed")


def budget(h):
    markets, user = [h.market() for _ in range(10)], h.users(1,427)[0]
    node = h.processes[-1]
    for market in markets:
        h.ready(node,market)
    def attempt(i):
        return h.request(node,"POST",f"/v1/markets/{markets[i%10]}/orders",
                         dict(outcome="YES",side="BUY",price=40,qty=1),user,uid())[0]
    with concurrent.futures.ThreadPoolExecutor(max_workers=200) as workers:
        statuses = list(workers.map(attempt,range(200)))
    free, held = h.owner.execute("select free_units,held_units from wallets where owner_id=%s and asset_key='SEDI'", (user[0],)).fetchone()
    assert held<=427 and free>=0 and free+held==427, (free,held)
    assert h.owner.execute("select count(*) from orders where account_id=%s",(user[0],)).fetchone()[0] == 10
    h.reconcile()
    return dict(requests=200, markets=10, free=free, held=held, statuses={s:statuses.count(s) for s in set(statuses)})


def lifecycle(h):
    market,user=h.market(),h.users(1,427)[0]
    node=h.processes[-1]
    h.ready(node,market)
    other=h.start()
    h.ready(other,market)
    initial=h.owner.execute("select owner_epoch from markets where id=%s",(market,)).fetchone()[0]
    response,_=h.place(node,market,user,qty=2)
    h.order(node,user,response["order_id"])
    h.owner.execute("update markets set status='SUSPENDED',version=version+1 where id=%s",(market,))
    wait_for(lambda:h.request(node,"GET",f"/v1/markets/{market}/book")[1].get("mode")=="SUSPENDED",label="suspended core")
    status,error,_=h.request(node,"POST",f"/v1/markets/{market}/orders",dict(outcome="YES",side="BUY",price=40,qty=1),user,uid())
    assert status==409 and error["error"]["code"]=="MARKET_SUSPENDED",(status,error)
    status,_,_=h.request(node,"DELETE",f"/v1/orders/{response['order_id']}",user=user)
    assert status in (200,202)
    h.order(node,user,response["order_id"],terminal=True)
    h.owner.execute("update markets set status='OPEN',version=version+1 where id=%s",(market,))
    wait_for(lambda:h.request(node,"GET",f"/v1/markets/{market}/book")[1].get("mode")=="OPEN",label="resumed core")
    response,_=h.place(node,market,user,qty=2)
    h.order(node,user,response["order_id"])
    h.owner.execute("update markets set status='RESOLUTION_PENDING',version=version+1 where id=%s",(market,))
    wait_for(lambda:h.request(node,"GET",f"/v1/markets/{market}/book")[1].get("mode")=="CLOSED",label="closed core")
    h.order(node,user,response["order_id"],terminal=True)
    assert h.owner.execute("select count(*) from holds where status='open' and ref_id=%s",(response["order_id"],)).fetchone()[0]==0
    assert h.owner.execute("select owner_epoch from markets where id=%s",(market,)).fetchone()[0]==initial
    h.reconcile()
    return dict(commands=h.differential(market),cross_node_genesis="passed",suspend_resume_close="passed")


def admission_crashes(h):
    h.stop_nodes()
    market,user=h.market(),h.users(1)[0]
    node=h.start(proxy_pg=True)
    h.ready(node,market)
    h.pg_proxy.barrier.clear()
    h.pg_proxy.release.clear()
    h.pg_proxy.frontier_pause=True
    assert h.pg_proxy.barrier.wait(5),"frontier read barrier not reached"
    key=uid()
    body=dict(outcome="YES",side="BUY",price=40,qty=1)
    connection=http.client.HTTPConnection("127.0.0.1",node["port"],timeout=0.05)
    connection.request("POST",f"/v1/markets/{market}/orders",json.dumps(body),
                       {"Content-Type":"application/json","Cookie":"say_session="+user[1],"Idempotency-Key":key})
    wait_for(lambda:h.owner.execute("select order_id from idempotency_records where account_id=%s and idem_key=%s",(user[0],key)).fetchone(),label="committed admission")
    with contextlib.suppress(TimeoutError):
        connection.getresponse()
    connection.close()
    order_id=str(h.owner.execute("select order_id from idempotency_records where account_id=%s and idem_key=%s",(user[0],key)).fetchone()[0])
    h.kill(node)
    h.pg_proxy.release.set()
    successor=h.start()
    retry,_=h.place(successor,market,user,key=key)
    assert retry["order_id"]==order_id
    h.order(successor,user,order_id)
    assert h.owner.execute("select count(*) from orders where account_id=%s",(user[0],)).fetchone()[0]==1
    assert h.owner.execute("select count(*) from holds where ref_id=%s",(order_id,)).fetchone()[0]==1
    h.reconcile()
    return dict(windows=["W1 admission before actor","W6 client timeout after admission"],commands=h.differential(market))


def committed_crash(h):
    h.stop_nodes()
    market,user=h.market(),h.users(1)[0]
    node=h.start(proxy_pg=True)
    h.ready(node,market)
    epoch=h.owner.execute("select owner_epoch from markets where id=%s",(market,)).fetchone()[0]
    h.pg_proxy.barrier.clear()
    h.pg_proxy.release.clear()
    h.pg_proxy.commit_pause=True
    response,_=h.place(node,market,user)
    assert h.pg_proxy.barrier.wait(5),"commit reply barrier not reached"
    assert h.owner.execute("select state from market_commands where order_id=%s",(response["order_id"],)).fetchone()[0]=="DONE"
    h.kill(node)
    h.pg_proxy.release.set()
    successor=h.start()
    wait_for(lambda:h.owner.execute("select owner_epoch from markets where id=%s",(market,)).fetchone()[0]>epoch,label="successor epoch")
    h.ready(successor,market)
    order=h.order(successor,user,response["order_id"])
    assert order["status"]=="OPEN"
    h.reconcile()
    return dict(window="W2 committed before reply/apply",commands=h.differential(market))


def owner_fence(h):
    h.stop_nodes()
    market,user=h.market(),h.users(1)[0]
    node=h.start(proxy_pg=True)
    h.ready(node,market)
    original=h.owner.execute("select node_id,epoch from market_owners where market_id=%s",(market,)).fetchone()
    competitor=h.start()
    time.sleep(0.3)
    assert h.owner.execute("select node_id,epoch from market_owners where market_id=%s",(market,)).fetchone()==original
    h.pg_proxy.barrier.clear()
    h.pg_proxy.fenced.clear()
    h.pg_proxy.release.clear()
    h.pg_proxy.before_commit_pause=True
    response,_=h.place(node,market,user)
    assert h.pg_proxy.barrier.wait(5),"pre-commit barrier not reached"
    os.kill(node["process"].pid,signal.SIGSTOP)
    time.sleep(10.2)
    h.pg_proxy.release.set()
    assert h.pg_proxy.fenced.wait(5),"final database guard did not reject expired owner"
    h.kill(node)
    h.ready(competitor,market)
    h.order(competitor,user,response["order_id"])
    current=h.owner.execute("select node_id,epoch from market_owners where market_id=%s",(market,)).fetchone()
    assert current[0]!=original[0] and current[1]>original[1]
    h.reconcile()
    return dict(window="W4 lease expiration before final guard",epochs=[original[1],current[1]],commands=h.differential(market))


def outbox_crashes(h):
    h.stop_nodes()
    market,user=h.market(),h.users(1)[0]
    node=h.start()
    h.ready(node,market)
    h.redis_proxy.outage()
    response,_=h.place(node,market,user)
    h.order(node,user,response["order_id"])
    assert h.owner.execute("select count(*) from outbox_events where market_id=%s and published_at is null",(market,)).fetchone()[0]>0
    h.kill(node)
    h.redis_proxy.enabled=True
    h.redis_proxy.barrier.clear()
    h.redis_proxy.redis_target="stream:market:"+market
    h.redis_proxy.redis_drop=True
    h.owner.execute("update outbox_events set next_attempt_at=clock_timestamp() where market_id=%s",(market,))
    successor=h.start()
    assert h.redis_proxy.barrier.wait(15),"Redis publication reply barrier not reached"
    h.redis_proxy.outage()
    stream="stream:market:"+market
    events=h.redis.xrange(stream)
    assert len(events)==1,events
    event_id=events[0][1]["id"]
    assert h.owner.execute("select published_at from outbox_events where id=%s",(event_id,)).fetchone()[0] is None
    h.kill(successor)
    h.owner.execute("update outbox_events set claim_until=clock_timestamp()-interval '1 second',next_attempt_at=clock_timestamp() where market_id=%s and published_at is null",(market,))
    h.redis_proxy.enabled=True
    h.start()
    wait_for(lambda:h.owner.execute("select count(*) from outbox_events where market_id=%s and published_at is null",(market,)).fetchone()[0]==0,label="outbox drain")
    delivered=h.redis.xrange(stream)
    assert sum(value["id"]==event_id for _,value in delivered)==1,delivered
    h.reconcile()
    return dict(windows=["W3 commit before outbox publication","W5 Redis append before PostgreSQL acknowledgement"],deduplicated_event=event_id)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--owner",default=os.environ.get("TEST_DATABASE_URL","postgresql://say:say-test-only@127.0.0.1:55432/say_test?sslmode=disable"))
    parser.add_argument("--app",default=os.environ.get("TEST_APP_DATABASE_URL","postgresql://say_api:say-api-test-only@127.0.0.1:55432/say_test?sslmode=disable"))
    parser.add_argument("--redis",default=os.environ.get("TEST_REDIS_URL","redis://127.0.0.1:56379"))
    parser.add_argument("--output",type=Path,default=ROOT/"docs/exchange/runtime-results.json")
    parser.add_argument("--binary",type=Path,default=ROOT/"bin/say")
    args = parser.parse_args()
    h = Harness(args)
    try:
        h.record("financial_http",lambda:financial(h))
        h.record("golden_http_A_J",lambda:golden(h))
        h.record("cross_market_budget",lambda:budget(h))
        h.record("lifecycle_and_cross_node_views",lambda:lifecycle(h))
        h.record("admission_process_crashes",lambda:admission_crashes(h))
        h.record("commit_process_crash",lambda:committed_crash(h))
        h.record("two_owner_final_guard",lambda:owner_fence(h))
        h.record("outbox_process_crashes",lambda:outbox_crashes(h))
        args.output.write_text(json.dumps(dict(results=h.results),indent=2)+"\n")
    finally:
        h.close()


if __name__ == "__main__":
    main()
