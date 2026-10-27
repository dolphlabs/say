"""Resumable enumeration: each ordinal names one complete sequence of length 1..depth."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

from differential import uuid
from exchange import make_order
from parallel import ParallelCorpus
from test_exchange import policy


def alphabet(name):
    if name == "full":
        placements = [(outcome, side, price, qty, tif, account)
                      for outcome in ("YES", "NO") for side in ("BUY", "SELL") for price in range(1, 10)
                      for qty in range(1, 4) for tif in ("GTC", "IOC") for account in (11, 12, 13)]
    else:
        placements = [
            ("YES", "BUY", 5, 2, "GTC", 11), ("NO", "BUY", 5, 2, "GTC", 12),
            ("YES", "SELL", 5, 2, "GTC", 12), ("NO", "SELL", 5, 2, "GTC", 11),
            ("YES", "BUY", 9, 3, "IOC", 13), ("NO", "BUY", 9, 3, "IOC", 13),
            ("YES", "SELL", 1, 3, "IOC", 13), ("NO", "SELL", 1, 3, "IOC", 13),
            ("YES", "BUY", 1, 1, "GTC", 11), ("NO", "SELL", 9, 1, "GTC", 12),
        ]
    cancels = [(target, account) for target in range(1, 5) for account in (11, 12, 13)] if name == "full" else [(1, 11), (1, 12)]
    return [("Place", token) for token in placements] + [("Cancel", token) for token in cancels]


def sequence(ordinal, size, depth):
    for length in range(1, depth+1):
        count = size ** length
        if ordinal < count:
            result = [0] * length
            for i in reversed(range(length)):
                result[i], ordinal = ordinal % size, ordinal // size
            return result
        ordinal -= count
    raise ValueError("ordinal is outside enumeration")


def run(args):
    started = time.monotonic()
    tokens = alphabet(args.alphabet)
    total = sum(len(tokens)**n for n in range(1, args.depth+1))
    end = total if args.count is None else min(total, args.start + args.count)
    if args.start < 0 or args.start >= total or args.shards < 1 or not 0 <= args.shard < args.shards:
        raise ValueError("invalid range or shard")
    directory = Path(args.output) if args.output else Path(tempfile.mkdtemp(prefix="say-exhaustive-"))
    corpus = ParallelCorpus(directory, args.workers)
    cases = 0
    first = args.start + ((args.shard - args.start) % args.shards)
    for ordinal in range(first, end, args.shards):
        state = corpus.init(policy(10), 36, 8)
        for depth, index in enumerate(sequence(ordinal, len(tokens), args.depth), 1):
            kind, token = tokens[index]
            seq = state.last_seq + 1
            if kind == "Place":
                outcome, side, price, qty, tif, account = token
                group = uuid(777) if account in (11, 13) else ""
                order = make_order(state.policy, seq, depth, account, outcome, side, price, qty, tif, group)
                command = dict(kind=kind, seq=seq, ref=uuid(depth), order=order)
            else:
                target, account = token
                command = dict(kind=kind, seq=seq, ref=uuid(80000+depth), order_id=uuid(target), account_id=uuid(account))
            corpus.command(state, command, True)
        cases += 1
    manifest = corpus.finish()
    metadata = dict(alphabet=args.alphabet, alphabet_size=len(tokens), depth=args.depth, total_sequences=total,
                    start=args.start, end=end, shard=args.shard, shards=args.shards, checked_sequences=cases, commands=corpus.check_count)
    (directory / "coverage.json").write_text(json.dumps(metadata, indent=2))
    print(json.dumps(dict(stage="generated", **metadata)), flush=True)
    completed = subprocess.run([args.binary, str(manifest)], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if completed.returncode:
        raise RuntimeError(f"native exhaustive comparison failed; retained {directory}\n{completed.stdout[-4000:]}\n{completed.stderr[-2000:]}")
    result = json.loads(completed.stdout.splitlines()[-1])
    assert result["commands"] == corpus.check_count
    print(json.dumps(dict(status="passed", seconds=round(time.monotonic()-started, 3), **metadata)), flush=True)
    if not args.output:
        shutil.rmtree(directory)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", default="/private/tmp/say-core-parallel")
    parser.add_argument("--alphabet", choices=("reduced", "full"), default="reduced")
    parser.add_argument("--depth", type=int, choices=range(1, 5), default=4)
    parser.add_argument("--start", type=int, default=0)
    parser.add_argument("--count", type=int)
    parser.add_argument("--shard", type=int, default=0)
    parser.add_argument("--shards", type=int, default=1)
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--output")
    run(parser.parse_args())
