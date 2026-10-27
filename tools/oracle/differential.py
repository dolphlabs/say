"""Independent admission/ledger model plus JSONL comparison with the native core."""
from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path
import random
import subprocess
import tempfile
import time

from exchange import Exchange, MAX_INT, checked, make_order
from test_exchange import policy


def uuid(number):
    return f"00000000-0000-4000-a000-{number:012d}"


def native_record(record):
    result = copy.deepcopy(record)
    result["decision"] = result.pop("result")
    result.setdefault("full_state_hash", None)
    return result


def normalize(response):
    value = copy.deepcopy(response)
    if value.get("transition") is None:
        value.pop("transition", None)
    elif "transition" in value:
        tr = value["transition"]
        tr["result"] = tr.pop("decision")
        if tr.get("full_state_hash") is None:
            tr.pop("full_state_hash", None)
    return value


class ShadowLedger:
    def __init__(self, p, pairs=320):
        self.policy = p
        self.free = {}
        self.held = {}
        self.holds = {}
        self.closed_holds = set()
        self.keys = set()
        self.fee_orders = set()
        self.accounts = [uuid(i) for i in range(11, 31)]
        self.kinds = {a: "bot" if i >= 15 else "user" for i, a in enumerate(self.accounts)}
        self.assets = ("SEDI", "YES:" + p["market_id"], "NO:" + p["market_id"])
        for a in self.accounts:
            self.free[(self.kinds[a], a, "SEDI")] = 1_000_000
            for asset in self.assets[1:]:
                self.free[(self.kinds[a], a, asset)] = pairs // len(self.accounts)
        for asset in self.assets[1:]:
            self.free[("system", "system:shares:" + p["market_id"], asset)] = -pairs
        self.free[("system", "system:collateral:" + p["market_id"], "SEDI")] = p["V"] * pairs
        self.free[("system", "system:issuance", "SEDI")] = -20_000_000 - p["V"] * pairs

    def reserve(self, order):
        amounts = [("SEDI", order["sedi_hold_id"], order["sedi_original"])]
        if order["side"] == "SELL":
            amounts.append((order["outcome"] + ":" + self.policy["market_id"], order["share_hold_id"], order["qty"]))
        for asset, hold, amount in amounts:
            key = (order["owner_kind"], order["account_id"], asset)
            if hold in self.holds or hold in self.closed_holds or self.free.get(key, 0) < amount:
                return False
        for asset, hold, amount in amounts:
            key = (order["owner_kind"], order["account_id"], asset)
            self.free[key] -= amount
            self.held[key] = checked(self.held.get(key, 0) + amount)
            self.holds[hold] = [key, amount]
        return True

    def apply(self, transition, state):
        for posting in transition["postings"]:
            key = posting["business_key"]
            assert key not in self.keys, ("duplicate posting", key)
            self.keys.add(key)
            totals, spent = {}, {}
            for entry in posting["entries"]:
                who = entry["owner"]
                wallet = (who["kind"], who["id"], entry["asset_key"])
                amount = entry["delta"]
                assert amount and -MAX_INT - 1 <= amount <= MAX_INT
                asset = entry["asset_key"]
                totals[asset] = checked(totals.get(asset, 0) + amount)
                balances = self.held if entry["bucket"] == "held" else self.free
                balances[wallet] = checked(balances.get(wallet, 0) + amount)
                if entry["hold"]:
                    assert entry["bucket"] == "held" and amount < 0
                    assert self.holds[entry["hold"]][0] == wallet
                    spent[entry["hold"]] = spent.get(entry["hold"], 0) - amount
                if who["kind"] != "system" or entry["bucket"] == "held":
                    assert balances[wallet] >= 0, ("negative wallet", wallet)
            assert not any(totals.values()), ("unbalanced", posting)
            for hold in posting["holds"]:
                hold_id, amount = hold["hold_id"], hold["amount"]
                assert hold["op"] in ("consume", "release") and amount > 0
                wallet, available = self.holds[hold_id]
                assert wallet == (hold["owner"]["kind"], hold["owner"]["id"], hold["asset_key"])
                assert spent.pop(hold_id) == amount and available >= amount
                self.holds[hold_id][1] -= amount
            assert not spent
            if posting["kind"] == "FEE":
                order_id = posting["ref_id"]
                assert order_id not in self.fee_orders
                self.fee_orders.add(order_id)
        for hold_id in tuple(self.holds):
            if self.holds[hold_id][1] == 0:
                self.closed_holds.add(hold_id)
                del self.holds[hold_id]
        totals = {asset: 0 for asset in self.assets}
        held_by_wallet = {}
        for wallet, amount in self.free.items():
            totals[wallet[2]] += amount
        for wallet, amount in self.held.items():
            totals[wallet[2]] += amount
        assert not any(totals.values()), ("asset conservation", totals)
        for wallet, amount in self.holds.values():
            assert amount >= 0
            held_by_wallet[wallet] = held_by_wallet.get(wallet, 0) + amount
        assert all(held_by_wallet.get(k, 0) == v for k, v in self.held.items())
        collateral = self.free.get(("system", "system:collateral:" + self.policy["market_id"], "SEDI"), 0)
        assert collateral == state.collateral == state.pairs * self.policy["V"]
        assert self.free.get(("system", "system:fees", "SEDI"), 0) == len(self.fee_orders)
        for asset in self.assets[1:]:
            assert self.free[("system", "system:shares:" + self.policy["market_id"], asset)] == -state.pairs
        for order in state.orders:
            sedi = order["remaining"] * order["limit"] if order["side"] == "BUY" else 0
            sedi += not order["fee_paid"]
            assert self.holds.get(order["sedi_hold_id"], [None, 0])[1] == sedi
            if order["side"] == "SELL":
                assert self.holds[order["share_hold_id"]][1] == order["remaining"]


class Corpus:
    def __init__(self, stream):
        self.stream = stream
        self.expected = []
        self.commands = 0
        self.mode_counts = {}

    def send(self, request, expected=None):
        self.stream.write(json.dumps(request, separators=(",", ":")) + "\n")
        if expected is not None:
            self.expected.append(expected)

    def state(self, state):
        return {"snapshot": state.snapshot(), "full_hash": state.full_hash()}

    def init(self, p, pairs=0, capacity=128):
        state = Exchange(p, pairs)
        self.send(dict(op="init", policy=p, pairs=pairs, capacity=capacity), self.state(state))
        return state

    def command(self, state, command, compact=False, ledger=None):
        self.commands += 1
        before = state.snapshot()
        try:
            planned = state.plan(command)
        except ValueError as error:
            self.send(dict(op="step", command=command, expected_state_hash=state.state_hash, expected_full_hash=state.full_hash()), {"error": str(error)})
            assert state.snapshot() == before
            return None
        assert state.snapshot() == before
        state.apply(planned)
        transition = planned.transition
        if ledger:
            ledger.apply(transition, state)
        for fill in transition["fills"]:
            self.mode_counts[fill["mode"]] = self.mode_counts.get(fill["mode"], 0) + 1
        if compact:
            self.send(dict(op="check", command=command, expected_state_hash=state.state_hash, expected_full_hash=state.full_hash()))
        else:
            expected = self.state(state)
            expected["transition"] = transition
            self.send(dict(op="step", command=command), expected)
        return transition

    def place(self, state, number, account, outcome, side, price, qty, tif="GTC", group="", compact=False, ledger=None):
        order = make_order(state.policy, state.last_seq + 1, number, account, outcome, side, price, qty, tif, group,
                           "bot" if account >= 26 and account <= 30 else "user")
        if ledger and not ledger.reserve(order):
            return None
        return self.command(state, dict(kind="Place", seq=order["accepted_seq"], ref=order["id"], order=order), compact, ledger)


def golden(corpus):
    p = policy()
    state = corpus.init(p, 1)
    corpus.place(state, 1, 11, "YES", "SELL", 60, 1)
    corpus.place(state, 2, 12, "YES", "BUY", 75, 1)
    state = corpus.init(p)
    corpus.place(state, 1, 11, "NO", "BUY", 45, 1)
    corpus.place(state, 2, 12, "YES", "BUY", 70, 1)
    corpus.place(state, 3, 11, "NO", "SELL", 40, 1)
    corpus.place(state, 4, 12, "YES", "SELL", 50, 1)
    state = corpus.init(p, 2)
    corpus.place(state, 1, 11, "NO", "BUY", 40, 2)
    corpus.place(state, 2, 12, "NO", "SELL", 35, 2)
    state = corpus.init(p, 3)
    corpus.place(state, 1, 11, "YES", "SELL", 58, 3)
    corpus.place(state, 2, 12, "NO", "BUY", 42, 5)
    corpus.place(state, 3, 13, "YES", "BUY", 60, 6)
    corpus.place(state, 4, 14, "YES", "BUY", 58, 2)
    state = corpus.init(p, 370)
    for i, (price, qty) in enumerate(((58, 80), (59, 110), (61, 180)), 1):
        corpus.place(state, i, 10+i, "YES", "SELL", price, qty)
    corpus.place(state, 4, 14, "YES", "BUY", 61, 250)
    state = corpus.init(p, 4)
    corpus.place(state, 1, 11, "YES", "SELL", 58, 4, group=uuid(777))
    corpus.place(state, 2, 12, "YES", "BUY", 58, 10, group=uuid(777))
    corpus.place(state, 3, 13, "YES", "BUY", 58, 10, "IOC")
    h_policy = policy(200); h_policy.update(min_price=2, max_price=198)
    state = corpus.init(h_policy, 3)
    corpus.place(state, 1, 11, "YES", "SELL", 120, 3)
    corpus.place(state, 2, 12, "YES", "BUY", 120, 3)
    state = corpus.init(p, 5)
    corpus.place(state, 1, 11, "YES", "SELL", 58, 5)
    corpus.place(state, 2, 12, "YES", "BUY", 60, 2)
    corpus.place(state, 3, 13, "YES", "BUY", 60, 3)
    state = corpus.init(p)
    corpus.place(state, 1, 11, "NO", "BUY", 40, 2)
    order = make_order(p, 2, 2, 12, "YES", "BUY", 70, 2)
    corpus.command(state, dict(kind="RejectPlace", seq=2, ref=uuid(2), order=order, reason="TRADING_HALTED"))
    # Plan/discard, restore shuffled queues, replay a decided tail, and all control commands.
    state = corpus.init(p)
    corpus.place(state, 1, 11, "NO", "BUY", 40, 5)
    corpus.place(state, 2, 12, "NO", "BUY", 40, 5)
    before = state.snapshot()
    candidate = dict(kind="Place", seq=3, ref=uuid(3), order=make_order(p, 3, 3, 13, "YES", "BUY", 65, 4))
    planned = state.plan(candidate)
    expected = corpus.state(state); expected["transition"] = planned.transition
    corpus.send(dict(op="plan", command=candidate), expected)
    corpus.send(dict(op="discard"), corpus.state(state))
    shuffled = copy.deepcopy(before); shuffled["orders"].reverse()
    corpus.send(dict(op="restore", snapshot=shuffled, capacity=32), corpus.state(state))
    tail = []
    for i, kind in enumerate(("Suspend", "Resume", "Snapshot", "Close", "Resume", "Snapshot"), 3):
        command = dict(kind=kind, seq=i, ref=uuid(80000+i))
        tail.append(corpus.command(state, command))
    corpus.send(dict(op="replay", snapshot=before, transitions=[native_record(r) for r in tail], capacity=32), corpus.state(state))
    bad = copy.deepcopy(tail[0]); bad["result"] = "FORBIDDEN"
    corpus.send(dict(op="replay", snapshot=before, transitions=[native_record(bad)], capacity=32), {"error": "TRANSITION_HASH_MISMATCH"})


def random_trace(corpus, count, seed, trace_length=512):
    rng = random.Random(seed)
    compact_checks = 0
    state = None
    ledger = None
    for step in range(count):
        if state is None or step % trace_length == 0 or state.mode == "CLOSED":
            if state is not None:
                corpus.send(dict(op="checked"), dict(checked=compact_checks, seq=state.last_seq, state_hash=state.state_hash, full_hash=state.full_hash()))
            p = policy(rng.choice((10, 50, 100, 200)))
            if rng.randrange(2):
                p.update(min_price=2, max_price=p["V"]-2, tick=2)
            state = corpus.init(p, 320)
            ledger = ShadowLedger(p)
            compact_checks = 0
        seq = state.last_seq + 1
        choice = rng.randrange(100)
        if choice < 62 and len(state.orders) < 64:
            side, outcome = rng.choice(("BUY", "SELL")), rng.choice(("YES", "NO"))
            price = rng.randrange(state.policy["min_price"], state.policy["max_price"]+1, state.policy["tick"])
            account, qty = rng.randrange(11, 31), rng.randrange(2, 9)
            tr = corpus.place(state, 1_000_000+step, account, outcome, side, price, qty, rng.choice(("GTC", "GTC", "IOC")),
                              uuid(777) if account in (11, 12) else "", True, ledger)
            if tr:
                compact_checks += 1
            else:
                command = dict(kind="Snapshot", seq=seq, ref=uuid(90_000_000+step))
                corpus.command(state, command, True, ledger); compact_checks += 1
        else:
            kind = rng.choices(("Cancel", "CancelAll", "Suspend", "Resume", "Snapshot"), (55, 25, 7, 7, 6))[0]
            command = dict(kind=kind, seq=seq, ref=uuid(90_000_000+step), account_id=uuid(rng.randrange(11, 31)))
            if kind == "Cancel":
                order = rng.choice(state.orders) if state.orders else None
                command.update(order_id=order["id"] if order else uuid(step), system=rng.randrange(5) == 0)
                if order and rng.randrange(4):
                    command["account_id"] = order["account_id"]
            if state.last_seq >= 8 and rng.randrange(trace_length * 2) == 0:
                command["kind"] = "Close"
            corpus.command(state, command, True, ledger); compact_checks += 1
    if state is not None:
        corpus.send(dict(op="checked"), dict(checked=compact_checks, seq=state.last_seq, state_hash=state.state_hash, full_hash=state.full_hash()))


def run(binary, commands=10000, seed=874392, keep=None):
    started = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="say-differential-") as directory:
        input_path = Path(directory) / "input.jsonl"
        with input_path.open("w") as stream:
            corpus = Corpus(stream)
            golden(corpus)
            random_trace(corpus, commands, seed)
        output_path = Path(directory) / "output.jsonl"
        with input_path.open("r") as source, output_path.open("w") as target:
            completed = subprocess.run([binary], stdin=source, stdout=target, stderr=subprocess.PIPE, text=True)
        if completed.returncode:
            raise RuntimeError(f"native driver exited {completed.returncode}: {completed.stderr[-2000:]}")
        actual = [normalize(json.loads(line)) for line in output_path.read_text().splitlines()]
        if len(actual) != len(corpus.expected) or actual != corpus.expected:
            destination = Path(keep or "/private/tmp/say-differential-failure")
            destination.mkdir(parents=True, exist_ok=True)
            (destination / "input.jsonl").write_bytes(input_path.read_bytes())
            (destination / "actual.json").write_text(json.dumps(actual, indent=2))
            (destination / "expected.json").write_text(json.dumps(corpus.expected, indent=2))
            for i, (a, e) in enumerate(zip(actual, corpus.expected)):
                if a != e:
                    raise AssertionError(f"response {i} differs; reproduction: {destination}; actual={str(a)[:300]}; expected={str(e)[:300]}")
            raise AssertionError(f"response count {len(actual)} != {len(corpus.expected)}; reproduction: {destination}")
        print(json.dumps(dict(commands=corpus.commands, seed=seed, fills=corpus.mode_counts, seconds=round(time.monotonic()-started, 3), status="passed"), sort_keys=True))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", default="/private/tmp/say-core-driver")
    parser.add_argument("--commands", type=int, default=10000)
    parser.add_argument("--seed", type=int, default=874392)
    parser.add_argument("--keep")
    args = parser.parse_args()
    run(args.binary, args.commands, args.seed, args.keep)
