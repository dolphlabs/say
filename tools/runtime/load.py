from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
from pathlib import Path
import platform
import queue
import random
import statistics
import subprocess
import threading
import time

from acceptance import Harness, ROOT, uid, wait_for


def percentiles(samples):
    if not samples:
        return None
    values=sorted(samples)
    return {f"p{p}_ms":round(values[min(len(values)-1,len(values)*p//100)]*1000,3) for p in (50,95,99)}


def workload(h,node,markets,users,profile,rate,seconds,cancels=()):
    pending=queue.Queue(256)
    lock=threading.Lock()
    statuses={}
    latency=[]
    health=[]
    admitted=[]
    peak_rss=[0]
    stopped=threading.Event()
    def worker():
        while True:
            item=pending.get()
            if item is None:
                pending.task_done()
                return
            market,user,order_id=item
            started=time.monotonic()
            try:
                if order_id:
                    status,response,_=h.request(node,"DELETE",f"/v1/orders/{order_id}",user=user)
                else:
                    outcome="YES" if int(user[0][-1],16)%2 else "NO"
                    price=40 if outcome=="YES" else 60
                    status,response,_=h.request(node,"POST",f"/v1/markets/{market}/orders",
                        dict(outcome=outcome,side="BUY",price=price,qty=1),user,uid())
            except OSError:
                status,response=0,{}
            elapsed=time.monotonic()-started
            with lock:
                statuses[status]=statuses.get(status,0)+1
                latency.append(elapsed)
                if status in (200,202) and not order_id:
                    admitted.append(response["order_id"])
            pending.task_done()
    def probe():
        while not stopped.wait(0.1):
            started=time.monotonic()
            try:
                status,_,_=h.request(node,"GET","/healthz")
                assert status==200
                health.append(time.monotonic()-started)
            except OSError:
                health.append(10.0)
            try:
                rss=int(subprocess.check_output(["ps","-o","rss=","-p",str(node["process"].pid)],text=True).strip())
                peak_rss[0]=max(peak_rss[0],rss*1024)
            except (ValueError,subprocess.SubprocessError):
                pass
    workers=[threading.Thread(target=worker) for _ in range(64)]
    for thread in workers:
        thread.start()
    probe_thread=threading.Thread(target=probe)
    probe_thread.start()
    rng=random.Random(874392)
    start=time.monotonic()
    offered,dropped=0,0
    try:
        while time.monotonic()-start<seconds:
            now=time.monotonic()
            target=start+offered/rate
            if target>now:
                time.sleep(target-now)
            market=markets[0] if profile in ("hot","postgres_50ms") and rng.random()<0.8 else rng.choice(markets)
            user=rng.choice(users)
            order_id=""
            if cancels:
                market,user,order_id=rng.choice(cancels)
            offered+=1
            try:
                pending.put_nowait((market,user,order_id))
            except queue.Full:
                dropped+=1
        pending.join()
    finally:
        for _ in workers:
            pending.put(None)
        for thread in workers:
            thread.join()
        stopped.set()
        probe_thread.join()
    return dict(offered=offered,client_dropped=dropped,http_attempts=len(latency),statuses=statuses,
                http_latency=percentiles(latency),health_latency=percentiles(health),peak_rss_bytes=peak_rss[0],
                admitted=len(admitted),offered_seconds=seconds,wall_seconds=round(time.monotonic()-start,3))


def profile(args,name):
    h=Harness(args)
    try:
        market_count=1000 if name=="distributed_1000" else 20 if name=="cancel_storm" else 10
        markets=[h.market() for _ in range(market_count)]
        users=h.users(20,1000000000)
        node=h.start(reply="0ms",settings={"EXCHANGE_POLL":"250ms","DB_POOL_SIZE":"64",
                                           "EXCHANGE_SNAPSHOT_EVERY":"60s","EXCHANGE_SNAPSHOT_COMMANDS":"5000"})
        recovery_start=time.monotonic()
        wait_for(lambda:h.owner.execute("select count(*) from markets where runtime_status='READY'").fetchone()[0]==market_count,
                 timeout=180,label="all load markets ready")
        startup_seconds=time.monotonic()-recovery_start
        cancels=[]
        if name=="cancel_storm":
            def seed(i):
                market,user=markets[i%market_count],users[i%len(users)]
                response,_=h.place(node,market,user)
                return market,user,response["order_id"]
            with concurrent.futures.ThreadPoolExecutor(32) as pool:
                cancels=list(pool.map(seed,range(1000)))
            wait_for(lambda:h.owner.execute("select count(*) from market_commands where state='PENDING'").fetchone()[0]==0,
                     timeout=120,label="cancel seed drain")
        if name=="postgres_50ms":
            h.owner.execute("""create function runtime_latency() returns trigger language plpgsql as $$
                begin perform pg_sleep(0.05); return new; end $$""")
            h.owner.execute("create trigger runtime_latency before update on market_commands for each row when (old.state='PENDING' and new.state<>'PENDING') execute function runtime_latency()")
        outage_start=None
        if name=="redis_outage_60s":
            h.redis_proxy.outage()
            outage_start=time.monotonic()
        data=workload(h,node,markets,users,name,args.rate,args.seconds,cancels)
        if outage_start is not None:
            while time.monotonic()-outage_start<60:
                time.sleep(min(1,60-(time.monotonic()-outage_start)))
            h.redis_proxy.enabled=True
            data["redis_outage_seconds"]=round(time.monotonic()-outage_start,3)
        drain_start=time.monotonic()
        try:
            wait_for(lambda:h.owner.execute("select count(*) from market_commands where state='PENDING'").fetchone()[0]==0,
                     timeout=180,label="command drain")
            data["drained"]=True
        except AssertionError:
            data["drained"]=False
        data["command_drain_seconds"]=round(time.monotonic()-drain_start,3)
        row=h.owner.execute("select count(*) filter(where state='DONE'),count(*) filter(where state='REJECTED'),count(*) filter(where state='PENDING') from market_commands").fetchone()
        data.update(completed=row[0],rejected_commands=row[1],pending=row[2])
        data["degraded_markets"]=h.owner.execute("select count(*) from markets where runtime_status='DEGRADED'").fetchone()[0]
        data["owner_epochs"]=h.owner.execute("select max(owner_epoch) from markets").fetchone()[0]
        data["startup_recovery_seconds"]=round(startup_seconds,3)
        if outage_start is not None:
            delivery_start=time.monotonic()
            wait_for(lambda:h.owner.execute("select count(*) from outbox_events where audience<>'legacy' and published_at is null").fetchone()[0]==0,
                     timeout=150,label="Redis outage delivery drain")
            data["outbox_drain_seconds"]=round(time.monotonic()-delivery_start,3)
        data["outbox_pending"]=h.owner.execute("select count(*) from outbox_events where audience<>'legacy' and published_at is null").fetchone()[0]
        h.reconcile()
        data["reconciliation"]="passed"
        data["markets"]=market_count
        data["profile"]=name
        return data
    finally:
        h.close()


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument("--owner",default=os.environ.get("TEST_DATABASE_URL","postgresql://say:say-test-only@127.0.0.1:55432/say_test?sslmode=disable"))
    parser.add_argument("--app",default=os.environ.get("TEST_APP_DATABASE_URL","postgresql://say_api:say-api-test-only@127.0.0.1:55432/say_test?sslmode=disable"))
    parser.add_argument("--redis",default=os.environ.get("TEST_REDIS_URL","redis://127.0.0.1:56379"))
    parser.add_argument("--profile",choices=["hot","distributed_1000","cancel_storm","postgres_50ms","redis_outage_60s","all"],default="all")
    parser.add_argument("--seconds",type=float,default=5)
    parser.add_argument("--rate",type=int,default=2000)
    parser.add_argument("--output",type=Path,default=ROOT/"docs/exchange/runtime-load-results.json")
    parser.add_argument("--binary",type=Path,default=ROOT/"bin/say")
    args=parser.parse_args()
    profiles=["hot","distributed_1000","cancel_storm","postgres_50ms","redis_outage_60s"] if args.profile=="all" else [args.profile]
    report=dict(platform=platform.platform(),machine=platform.machine(),compiler=subprocess.check_output(["slangc","--version"],text=True).strip(),
                rate=args.rate,seconds=args.seconds,workers=64,client_queue=256,db_pool=64,heartbeat_pool=2,poll_ms=250,results=[])
    for name in profiles:
        data=profile(args,name)
        report["results"].append(data)
        args.output.write_text(json.dumps(report,indent=2)+"\n")
        print(json.dumps(data),flush=True)


if __name__=="__main__":
    main()
