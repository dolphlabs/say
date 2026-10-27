"""Generate independently checked traces; run each book on a native spawned worker."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

from differential import Corpus, random_trace
from exchange import ORDER_FIELDS


def complete_command(command):
    empty = {key: "" if key in ("id", "account_id", "owner_kind", "owner_group", "outcome", "side", "tif", "sedi_hold_id", "share_hold_id") else 0 for key in ORDER_FIELDS}
    empty["fee_paid"] = False
    result = dict(kind=command["kind"], seq=command["seq"], ref=command["ref"], order=empty,
                  order_id="", account_id="", system=False, reason="USER_CANCEL")
    result.update(command)
    return result


class ParallelCorpus(Corpus):
    def __init__(self, directory, workers=4):
        super().__init__(None)
        self.directory = Path(directory)
        self.directory.mkdir(parents=True, exist_ok=True)
        self.workers = workers
        self.current = None
        self.bundle = []
        self.files = []
        self.case_count = 0
        self.check_count = 0

    def send(self, request, expected=None):
        op = request["op"]
        if op == "init":
            self.finish_case()
            self.current = dict(policy=request["policy"], pairs=request.get("pairs", 0), capacity=request.get("capacity", 128), commands=[])
        elif op == "check":
            self.current["commands"].append(dict(command=complete_command(request["command"]), expected_state_hash=request["expected_state_hash"], expected_full_hash=request["expected_full_hash"]))
            self.check_count += 1
        elif op == "step" and expected and "error" in expected:
            self.current["commands"].append(dict(command=complete_command(request["command"]), expected_error=expected["error"], expected_state_hash=request["expected_state_hash"], expected_full_hash=request["expected_full_hash"]))
            self.check_count += 1
        elif op == "checked":
            self.finish_case()
        else:
            raise ValueError(f"unsupported parallel operation {op}")

    def finish_case(self):
        if self.current is None:
            return
        if sum(len(c["commands"]) for c in self.bundle) + len(self.current["commands"]) > 16000:
            self.flush()
        self.bundle.append(self.current)
        self.current = None
        self.case_count += 1
        if len(self.bundle) >= 2048 or sum(len(c["commands"]) for c in self.bundle) >= 4096:
            self.flush()

    def flush(self):
        if not self.bundle:
            return
        path = (self.directory / f"cases-{len(self.files):07d}.json").resolve()
        path.write_text(json.dumps(dict(cases=self.bundle), separators=(",", ":")))
        if path.stat().st_size > 33554432:
            raise ValueError("case bundle exceeds native 32 MiB limit")
        self.files.append(str(path))
        self.bundle = []

    def finish(self):
        self.finish_case()
        self.flush()
        path = self.directory / "manifest.json"
        path.write_text(json.dumps(dict(files=self.files, workers=self.workers)))
        return path


def run(args):
    started = time.monotonic()
    directory = Path(args.output) if args.output else Path(tempfile.mkdtemp(prefix="say-parallel-"))
    corpus = ParallelCorpus(directory, args.workers)
    random_trace(corpus, args.commands, args.seed, args.trace_length)
    manifest = corpus.finish()
    generated = time.monotonic()
    print(json.dumps(dict(stage="generated", cases=corpus.case_count, commands=corpus.check_count, fills=corpus.mode_counts,
                          seconds=round(generated-started, 3), manifest=str(manifest))), flush=True)
    completed = subprocess.run([args.binary, str(manifest)], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if completed.returncode:
        for line in completed.stdout.splitlines():
            try:
                failure = json.loads(line)
            except json.JSONDecodeError:
                continue
            if failure.get("error") and failure.get("file"):
                shutil.copyfile(failure["file"], directory / "failed-case.json")
                break
        (directory / "failure.json").write_text(json.dumps(dict(seed=args.seed, commands=args.commands, trace_length=args.trace_length, stdout=completed.stdout, stderr=completed.stderr)))
        raise RuntimeError(f"native spawned-worker check failed; retained {directory}\n{completed.stdout[-4000:]}\n{completed.stderr[-2000:]}")
    summary = json.loads(completed.stdout.splitlines()[-1])
    assert summary["commands"] == corpus.check_count, summary
    print(json.dumps(dict(status="passed", commands=summary["commands"], cases=corpus.case_count, workers=args.workers, seed=args.seed,
                          fills=corpus.mode_counts, native_seconds=round(time.monotonic()-generated, 3), total_seconds=round(time.monotonic()-started, 3)), sort_keys=True), flush=True)
    if not args.output:
        shutil.rmtree(directory)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", default="/private/tmp/say-core-parallel")
    parser.add_argument("--commands", type=int, default=1000000)
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--trace-length", type=int, choices=range(1, 10001), default=512)
    parser.add_argument("--seed", type=int, default=874392)
    parser.add_argument("--output")
    run(parser.parse_args())
