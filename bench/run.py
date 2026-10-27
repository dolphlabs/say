"""Build, measure, and retain comparable raw benchmark results."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess

ROOT = Path(__file__).resolve().parent.parent


def run(command, env=None):
    return subprocess.run(command, cwd=ROOT, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)


def measure(command, environment, destination):
    env = dict(os.environ, **environment)
    completed = run(command, env)
    destination.write_text(completed.stdout)
    destination.with_suffix(".stderr.txt").write_text(completed.stderr)
    return [json.loads(line) for line in completed.stdout.splitlines()]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--samples", type=int, default=10000)
    parser.add_argument("--cycles", type=int, default=100)
    parser.add_argument("--go", default="go")
    parser.add_argument("--output", default="bench/results")
    args = parser.parse_args()
    result_dir = (ROOT / args.output).resolve()
    result_dir.mkdir(parents=True, exist_ok=True)
    binary_dir = ROOT / "bin"
    binary_dir.mkdir(exist_ok=True)
    for source, target in (("bench/slang/main.sl", "core-bench"), ("bench/slang/concurrent/main.sl", "core-concurrent")):
        completed = run(["python3", "bench/instrument.py", source, "-o", str(binary_dir / target)])
        (result_dir / (target + ".build.txt")).write_text(completed.stdout + completed.stderr)
    run([args.go, "-C", "bench/go-ref", "build", "-o", "../../bin/go-ref", "."])
    native = measure([str(binary_dir / "core-bench"), str(args.samples)], {"SLANG_WORKERS": "1"}, result_dir / "slang-single.jsonl")
    go = measure([str(binary_dir / "go-ref"), str(args.samples)], {"GOMAXPROCS": "1"}, result_dir / "go-single.jsonl")
    assert len(native) == len(go) == 6
    for a, b in zip(native, go):
        assert a["scenario"] == b["scenario"] and a["final_hash"] == b["final_hash"]
        assert len(a["samples_ns"]) == len(b["samples_ns"]) == args.samples
        assert a["gc_allocations"] == a["native_allocation_calls"] == a["memory_maps"] == b["gc_allocations"] == 0
        print(json.dumps({"scenario": a["scenario"], "slang_p99_ns": a["p99_ns"], "go_p99_ns": b["p99_ns"], "history_match": True}), flush=True)
    for workers in (1, 4):
        a = measure([str(binary_dir / "core-concurrent"), str(args.cycles)], {"SLANG_WORKERS": str(workers)}, result_dir / f"slang-concurrent-{workers}.jsonl")[0]
        b = measure([str(binary_dir / "go-ref"), "--concurrent", str(args.cycles)], {"GOMAXPROCS": str(workers)}, result_dir / f"go-concurrent-{workers}.jsonl")[0]
        assert a["history_digest"] == b["history_digest"] and a["checksum"] == b["checksum"] and a["commands"] == b["commands"] == 2000 * args.cycles
        print(json.dumps({"workers": workers, "slang_commands_s": a["commands_per_second"], "go_commands_s": b["commands_per_second"], "checksum_match": True}), flush=True)
    sources = sorted({*ROOT.glob("src/exchange/**/*.sl"), *ROOT.glob("bench/slang/**/*.sl"), *ROOT.glob("bench/go-ref/*.go"), ROOT / "bench/instrument.py", ROOT / "bench/run.py"})
    digests = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
    metadata = {"system": platform.platform(), "machine": platform.machine(), "cpu_count": os.cpu_count(), "samples": args.samples,
                "warmup_commands": 200, "concurrent_markets": 1000, "cycles": args.cycles, "source_sha256": digests,
                "slang_version": run(["slangc", "--version"]).stdout.strip(), "go_version": run([args.go, "version"]).stdout.strip()}
    (result_dir / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")


if __name__ == "__main__":
    main()
