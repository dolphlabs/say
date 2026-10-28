import argparse
import concurrent.futures
import json
import os
from pathlib import Path
import time

from acceptance import Harness, ROOT, wait_for


STEPS=((0,"YES","BUY",40,3),(1,"NO","BUY",60,3),(0,"YES","SELL",45,2),
       (2,"YES","BUY",50,2),(1,"NO","SELL",60,1),(3,"NO","BUY",65,1),
       (1,"NO","SELL",60,1),(2,"YES","SELL",35,1),(1,"NO","SELL",60,1),
       (0,"YES","SELL",35,1),(3,"NO","SELL",60,1),(2,"YES","SELL",35,1))


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument("--owner",default=os.environ.get("TEST_DATABASE_URL","postgresql://say:say-test-only@127.0.0.1:55432/say_test?sslmode=disable"))
    parser.add_argument("--app",default=os.environ.get("TEST_APP_DATABASE_URL","postgresql://say_api:say-api-test-only@127.0.0.1:55432/say_test?sslmode=disable"))
    parser.add_argument("--redis",default=os.environ.get("TEST_REDIS_URL","redis://127.0.0.1:56379"))
    parser.add_argument("--commands",type=int,default=100000)
    parser.add_argument("--markets",type=int,default=20)
    parser.add_argument("--output",type=Path,default=ROOT/"docs/exchange/runtime-differential-results.json")
    parser.add_argument("--binary",type=Path,default=ROOT/"bin/say")
    args=parser.parse_args()
    h=Harness(args)
    try:
        markets=[h.market() for _ in range(args.markets)]
        users=h.users(args.markets*4,1000000000)
        node=h.start(reply="0ms",settings={"DB_POOL_SIZE":"64","EXCHANGE_POLL":"10ms",
                                           "EXCHANGE_SNAPSHOT_EVERY":"60s","EXCHANGE_SNAPSHOT_COMMANDS":"1000"})
        wait_for(lambda:h.owner.execute("select count(*) from markets where runtime_status='READY'").fetchone()[0]==args.markets,
                 timeout=120,label="differential markets ready")
        started=time.monotonic()
        def run(lane):
            count=args.commands//args.markets+(lane<args.commands%args.markets)
            people=users[lane*4:lane*4+4]
            for i in range(count):
                who,outcome,side,price,qty=STEPS[i%len(STEPS)]
                response,_=h.place(node,markets[lane],people[who],outcome,side,price,qty)
                order=h.order(node,people[who],response["order_id"])
                assert order["status"]!="REJECTED",order
                if i and i%1000==0:
                    print(json.dumps(dict(lane=lane,commands=i,seconds=round(time.monotonic()-started,2))),flush=True)
            return count
        with concurrent.futures.ThreadPoolExecutor(args.markets) as workers:
            submitted=sum(workers.map(run,range(args.markets)))
        execution_seconds=time.monotonic()-started
        wait_for(lambda:h.owner.execute("select count(*) from market_commands where state='PENDING'").fetchone()[0]==0,
                 timeout=120,label="differential command drain")
        checked=sum(h.differential(market) for market in markets)
        assert checked==submitted==args.commands,(checked,submitted)
        h.reconcile()
        recovered=[]
        for market in markets:
            state=h.fixture("recover",market=market)
            expected=h.owner.execute("select committed_seq,rolling_hash from markets where id=%s",(market,)).fetchone()
            assert (state["last_seq"],state["state_hash"])==expected
            recovered.append(state["last_seq"])
        modes=dict(h.owner.execute("select mode,count(*) from fills group by mode").fetchall())
        result=dict(commands=checked,markets=args.markets,execution_seconds=round(execution_seconds,3),
                    commands_per_second=round(checked/execution_seconds,3),total_seconds=round(time.monotonic()-started,3),
                    modes=modes,reconciliation="passed",recovered_sequences=recovered,
                    distribution="deterministic 12-command cycles across all four execution modes")
        args.output.write_text(json.dumps(result,indent=2)+"\n")
        print(json.dumps(result),flush=True)
    finally:
        h.close()


if __name__=="__main__":
    main()
