from __future__ import annotations

import copy
import hashlib
from dataclasses import dataclass

MAX_INT = (1 << 63) - 1
ORDER_FIELDS = (
    "id", "account_id", "owner_kind", "owner_group", "outcome", "side", "limit", "qty", "remaining",
    "tif", "accepted_seq", "fee_paid", "sedi_hold_id", "share_hold_id", "sedi_original", "sedi_consumed",
    "sedi_released", "shares_original", "shares_consumed", "shares_released", "filled", "cancelled",
)


def checked(value: int) -> int:
    if not -(1 << 63) <= value <= MAX_INT:
        raise ValueError("OVERFLOW")
    return value


def canonical_uuid(value: str) -> bool:
    return len(value) == 36 and all(c == "-" if i in (8, 13, 18, 23) else c in "0123456789abcdef"
                                    for i, c in enumerate(value))


def put(parts: list[bytes], value) -> None:
    if isinstance(value, bool):
        value = int(value)
    raw = str(value).encode("utf-8")
    parts.extend((str(len(raw)).encode("ascii"), b":", raw))


def order_bytes(parts, order):
    for field in ORDER_FIELDS:
        put(parts, order[field])


def transition_bytes(t: dict) -> bytes:
    parts: list[bytes] = []
    for key in ("schema", "market_id", "season_id", "base_seq", "seq", "command_ref", "command_kind", "result", "mode"):
        put(parts, t[key])
    put(parts, len(t["fills"]))
    for fill in t["fills"]:
        for key in ("fill_index", "mode", "maker_order_id", "taker_order_id", "qty", "yes_price"):
            put(parts, fill[key])
    put(parts, len(t["order_updates"]))
    for update in t["order_updates"]:
        order_bytes(parts, update["order"])
        for key in ("status", "fee_charged_now", "cancel_reason"):
            put(parts, update[key])
    put(parts, t["rested"] is not None)
    if t["rested"] is not None:
        order_bytes(parts, t["rested"])
    put(parts, len(t["postings"]))
    for posting in t["postings"]:
        for key in ("business_key", "kind", "season_id", "market_id", "ref_type", "ref_id"):
            put(parts, posting[key])
        put(parts, len(posting["entries"]))
        for entry in posting["entries"]:
            for value in (entry["owner"]["kind"], entry["owner"]["id"], entry["asset_key"],
                          entry["bucket"], entry["delta"], entry["hold"]):
                put(parts, value)
        put(parts, len(posting["holds"]))
        for hold in posting["holds"]:
            for value in (hold["op"], hold["hold_id"], hold["owner"]["kind"], hold["owner"]["id"],
                          hold["asset_key"], hold["amount"]):
                put(parts, value)
    for value in (t["supply_delta"]["yes"], t["supply_delta"]["no"], t["collateral_delta"]):
        put(parts, value)
    put(parts, len(t["book_deltas"]))
    for level in t["book_deltas"]:
        for key in ("side", "yes_price", "new_level_qty"):
            put(parts, level[key])
    put(parts, len(t["trades"]))
    for trade in t["trades"]:
        for key in ("fill_index", "yes_price", "qty", "aggressor"):
            put(parts, trade[key])
    put(parts, t["last_price"] is not None)
    if t["last_price"] is not None:
        put(parts, t["last_price"])
    return b"".join(parts)


@dataclass
class Plan:
    transition: dict
    expected_snapshot: dict


class Exchange:
    def __init__(self, policy: dict, pairs=0):
        self.policy = dict(policy)
        if not canonical_uuid(policy["market_id"]) or not canonical_uuid(policy["season_id"]):
            raise ValueError("INVALID_POLICY")
        v, low, high, tick = (policy[k] for k in ("V", "min_price", "max_price", "tick"))
        if not (10 <= v <= 1000 and 1 <= low <= high < v and low + high == v and tick > 0
                and low % tick == 0 and (high - low) % tick == 0 and v % tick == 0):
            raise ValueError("INVALID_POLICY")
        if policy["max_order_qty"] <= 0 or policy["min_order_notional"] != 2:
            raise ValueError("INVALID_POLICY")
        self.orders: list[dict] = []
        self.mode = "OPEN"
        self.last_seq = 0
        self.state_hash = "00" * 32
        self.last_price = None
        self.pairs = checked(pairs)
        self.collateral = checked(v * pairs)
        if pairs < 0:
            raise ValueError("INVALID_SUPPLY")
        genesis = []
        put(genesis, "say.genesis.v1")
        for key in ("market_id", "season_id", "V", "min_price", "max_price", "tick", "max_order_qty", "min_order_notional"):
            put(genesis, policy[key])
        put(genesis, pairs)
        put(genesis, self.collateral)
        self.state_hash = hashlib.sha256(b"".join(genesis)).hexdigest()

    def normalized(self, order):
        bid = (order["side"], order["outcome"]) in (("BUY", "YES"), ("SELL", "NO"))
        return ("bid" if bid else "ask", order["limit"] if order["outcome"] == "YES" else self.policy["V"] - order["limit"])

    def ordered(self):
        return sorted(self.orders, key=lambda o: (0 if self.normalized(o)[0] == "bid" else 1,
                      self.normalized(o)[1], o["accepted_seq"], o["id"]))

    def levels(self):
        levels = {}
        for order in self.orders:
            key = self.normalized(order)
            levels[key] = checked(levels.get(key, 0) + order["remaining"])
        return levels

    def snapshot(self):
        return {"policy": copy.deepcopy(self.policy), "orders": copy.deepcopy(self.ordered()), "mode": self.mode,
                "last_seq": self.last_seq, "state_hash": self.state_hash, "last_price": self.last_price,
                "pairs": self.pairs, "collateral": self.collateral}

    def full_hash(self):
        parts = []
        put(parts, "say.book.v1")
        for key in ("market_id", "season_id", "V", "min_price", "max_price", "tick", "max_order_qty", "min_order_notional"):
            put(parts, self.policy[key])
        for value in (self.mode, self.last_seq, self.state_hash, self.pairs, self.collateral, self.last_price is not None):
            put(parts, value)
        if self.last_price is not None:
            put(parts, self.last_price)
        put(parts, len(self.orders))
        for order in self.ordered():
            order_bytes(parts, order)
        return hashlib.sha256(b"".join(parts)).hexdigest()

    def _fresh(self, order, seq):
        if not all(canonical_uuid(order[k]) for k in ("id", "account_id", "sedi_hold_id")):
            raise ValueError("INVALID_IDENTIFIER")
        if order["owner_kind"] not in ("user", "bot") or (order["owner_group"] and not canonical_uuid(order["owner_group"])):
            raise ValueError("INVALID_ORDER_FACTS")
        if order["outcome"] not in ("YES", "NO") or order["side"] not in ("BUY", "SELL") or order["tif"] not in ("GTC", "IOC"):
            raise ValueError("INVALID_ORDER")
        p, q = order["limit"], order["qty"]
        if not (self.policy["min_price"] <= p <= self.policy["max_price"] and p % self.policy["tick"] == 0):
            raise ValueError("INVALID_PRICE")
        if not (0 < q <= self.policy["max_order_qty"] and checked(p * q) >= self.policy["min_order_notional"]):
            raise ValueError("INVALID_QUANTITY")
        if order["accepted_seq"] != seq or order["remaining"] != q or order["fee_paid"] or any(order[k] for k in
                ("filled", "cancelled", "sedi_consumed", "sedi_released", "shares_consumed", "shares_released")):
            raise ValueError("INVALID_ORDER_FACTS")
        expected = checked(p * q + 1) if order["side"] == "BUY" else 1
        if order["sedi_original"] != expected or order["shares_original"] != (q if order["side"] == "SELL" else 0):
            raise ValueError("INVALID_HOLD_FACTS")
        if not order["sedi_hold_id"] or (order["side"] == "SELL" and not order["share_hold_id"]):
            raise ValueError("INVALID_HOLD_FACTS")
        if order["side"] == "SELL":
            reserved = sum(o["remaining"] for o in self.orders if o["side"] == "SELL" and o["outcome"] == order["outcome"])
            if not canonical_uuid(order["share_hold_id"]) or reserved + q > self.pairs:
                raise ValueError("INVALID_SUPPLY")
        if any(o["id"] == order["id"] for o in self.orders):
            raise ValueError("DUPLICATE_ORDER")

    def plan(self, command):
        if command["seq"] != self.last_seq + 1 or self.last_seq == MAX_INT:
            raise ValueError("INVALID_SEQUENCE")
        if not canonical_uuid(command["ref"]):
            raise ValueError("INVALID_COMMAND_REF")
        projected = copy.deepcopy(self)
        transition = projected._execute(command)
        transition["state_hash"] = hashlib.sha256(bytes.fromhex(self.state_hash) + transition_bytes(transition)).hexdigest()
        projected.last_seq = command["seq"]
        projected.state_hash = transition["state_hash"]
        if command["kind"] == "Snapshot":
            transition["full_state_hash"] = projected.full_hash()
        projected.verify()
        return Plan(transition, projected.snapshot())

    def _execute(self, cmd):
        p = self.policy
        before = self.levels()
        tr = {"schema": "say.transition.v1", "market_id": p["market_id"], "season_id": p["season_id"],
              "base_seq": self.last_seq, "prev_hash": self.state_hash, "seq": cmd["seq"], "command_ref": cmd["ref"],
              "command_kind": cmd["kind"], "result": "ACCEPTED", "mode": self.mode, "fills": [], "order_updates": [], "rested": None,
              "postings": [], "supply_delta": {"yes": 0, "no": 0}, "collateral_delta": 0,
              "book_deltas": [], "trades": [], "last_price": None}
        touched, original_fee, reasons, fees = {}, {}, {}, []

        def touch(order):
            if order["id"] not in touched:
                touched[order["id"]] = order
                original_fee[order["id"]] = order["fee_paid"]

        def owner(order):
            return {"kind": order["owner_kind"], "id": order["account_id"]}

        def system(name):
            return {"kind": "system", "id": "system:" + name}

        def entry(who, asset, delta, hold=""):
            checked(delta)
            return {"owner": who, "asset_key": asset, "bucket": "held" if hold else "free", "delta": delta, "hold": hold}

        def tx(key, kind, ref_type, ref_id, entries, holds):
            totals = {}
            for e in entries:
                if not e["delta"]:
                    raise ValueError("ZERO_ENTRY")
                totals[e["asset_key"]] = checked(totals.get(e["asset_key"], 0) + e["delta"])
            if any(totals.values()):
                raise ValueError("UNBALANCED_POSTING")
            return {"business_key": key, "kind": kind, "season_id": p["season_id"], "market_id": p["market_id"],
                    "ref_type": ref_type, "ref_id": ref_id, "metadata": "{}", "entries": entries, "holds": holds}

        def take(order, asset, amount, entries, holds):
            share = asset != "SEDI"
            hold = order["share_hold_id" if share else "sedi_hold_id"]
            key = "shares_consumed" if share else "sedi_consumed"
            order[key] = checked(order[key] + amount)
            entries.append(entry(owner(order), asset, -amount, hold))
            holds.append({"op": "consume", "hold_id": hold, "owner": owner(order), "asset_key": asset, "amount": amount})

        def fee(order):
            if order["fee_paid"]:
                return
            entries, holds = [], []
            take(order, "SEDI", 1, entries, holds)
            entries.append(entry(system("fees"), "SEDI", 1))
            order["fee_paid"] = True
            fees.append(tx("fee:" + order["id"], "FEE", "order", order["id"], entries, holds))

        def cancel(order, reason):
            touch(order)
            order["cancelled"] = checked(order["cancelled"] + order["remaining"])
            order["remaining"] = 0
            reasons[order["id"]] = reason

        kind = cmd["kind"]
        incoming = copy.deepcopy(cmd["order"]) if kind in ("Place", "RejectPlace") else None
        if kind in ("Place", "RejectPlace"):
            self._fresh(incoming, cmd["seq"])
        if kind == "RejectPlace":
            if cmd.get("reason") not in ("MARKET_NOT_OPEN", "MARKET_SUSPENDED", "MARKET_CLOSED", "TRADING_HALTED", "SEASON_NOT_ACTIVE", "MARKET_DEGRADED", "ACCOUNT_DISABLED"):
                raise ValueError("INVALID_REJECTION_REASON")
            tr["result"] = cmd["reason"]
            cancel(incoming, cmd["reason"])
        elif self.mode == "CLOSED" and kind != "Snapshot":
            tr["result"] = "MARKET_CLOSED"
            if incoming:
                cancel(incoming, "MARKET_CLOSED")
        elif kind == "Place":
            if self.mode == "SUSPENDED":
                tr["result"] = "MARKET_SUSPENDED"
                cancel(incoming, "MARKET_SUSPENDED")
            else:
                side, limit = self.normalized(incoming)
                while incoming["remaining"]:
                    candidates = [o for o in self.orders if self.normalized(o)[0] != side]
                    candidates.sort(key=lambda o: (self.normalized(o)[1] * (1 if side == "bid" else -1), o["accepted_seq"], o["id"]))
                    if not candidates:
                        break
                    maker = candidates[0]
                    x = self.normalized(maker)[1]
                    if (side == "bid" and limit < x) or (side == "ask" and limit > x):
                        break
                    if maker["account_id"] == incoming["account_id"] or (maker["owner_group"] and maker["owner_group"] == incoming["owner_group"]):
                        cancel(incoming, "SELF_TRADE_PREVENTED")
                        break
                    if not p["min_price"] <= x <= p["max_price"] or x % p["tick"]:
                        raise ValueError("INTERNAL_PRICE_OUT_OF_BAND")
                    touch(maker)
                    touch(incoming)
                    bid, ask = (incoming, maker) if side == "bid" else (maker, incoming)
                    q = min(maker["remaining"], incoming["remaining"])
                    mode = {("BUY", "SELL"): "TRANSFER_YES", ("SELL", "BUY"): "TRANSFER_NO",
                            ("BUY", "BUY"): "MINT", ("SELL", "SELL"): "MERGE"}[bid["side"], ask["side"]]
                    entries, holds = [], []
                    if mode.startswith("TRANSFER"):
                        buyer, seller = (bid, ask) if mode == "TRANSFER_YES" else (ask, bid)
                        asset = buyer["outcome"] + ":" + p["market_id"]
                        amount = checked((x if buyer["outcome"] == "YES" else p["V"] - x) * q)
                        take(buyer, "SEDI", amount, entries, holds)
                        entries.append(entry(owner(seller), "SEDI", amount))
                        take(seller, asset, q, entries, holds)
                        entries.append(entry(owner(buyer), asset, q))
                    elif mode == "MINT":
                        take(bid, "SEDI", checked(x * q), entries, holds)
                        take(ask, "SEDI", checked((p["V"] - x) * q), entries, holds)
                        entries.append(entry(system("collateral:" + p["market_id"]), "SEDI", checked(p["V"] * q)))
                        for order in (bid, ask):
                            asset = order["outcome"] + ":" + p["market_id"]
                            entries.extend((entry(system("shares:" + p["market_id"]), asset, -q), entry(owner(order), asset, q)))
                    else:
                        for order in (ask, bid):
                            asset = order["outcome"] + ":" + p["market_id"]
                            take(order, asset, q, entries, holds)
                            entries.append(entry(system("shares:" + p["market_id"]), asset, q))
                        entries.extend((entry(system("collateral:" + p["market_id"]), "SEDI", -checked(p["V"] * q)),
                                        entry(owner(ask), "SEDI", checked(x * q)), entry(owner(bid), "SEDI", checked((p["V"] - x) * q))))
                    index = len(tr["fills"])
                    tr["postings"].append(tx(f"fill:{p['market_id']}:{cmd['seq']}:{index}", "FILL" if mode.startswith("TRANSFER") else mode,
                                             "market_command", cmd["ref"], entries, holds))
                    tr["fills"].append({"fill_index": index, "mode": mode, "maker_order_id": maker["id"],
                                        "taker_order_id": incoming["id"], "qty": q, "yes_price": x})
                    tr["trades"].append({"fill_index": index, "yes_price": x, "qty": q, "aggressor": side})
                    for order in (maker, incoming):
                        order["remaining"] -= q
                        order["filled"] = checked(order["filled"] + q)
                        fee(order)
                    if mode in ("MINT", "MERGE"):
                        delta = q if mode == "MINT" else -q
                        self.pairs = checked(self.pairs + delta)
                        self.collateral = checked(self.collateral + p["V"] * delta)
                        tr["supply_delta"]["yes"] += delta
                        tr["supply_delta"]["no"] += delta
                        tr["collateral_delta"] = checked(tr["collateral_delta"] + p["V"] * delta)
                        if self.pairs < 0:
                            raise ValueError("INVALID_SUPPLY")
                    self.last_price = tr["last_price"] = x
                    self.orders = [o for o in self.orders if o["remaining"]]
                touch(incoming)
                if incoming["remaining"] and incoming["tif"] == "IOC":
                    cancel(incoming, "IOC_REMAINDER")
                if incoming["remaining"]:
                    self.orders.append(incoming)
        elif kind in ("Cancel", "CancelAll", "Close"):
            selected = self.ordered()
            if kind == "Cancel":
                selected = [o for o in selected if o["id"] == cmd["order_id"]]
                if not selected:
                    tr["result"] = "ORDER_NOT_OPEN"
                elif not cmd.get("system", False) and selected[0]["account_id"] != cmd.get("account_id"):
                    selected = []
                    tr["result"] = "FORBIDDEN"
            if kind == "CancelAll":
                selected = [o for o in selected if o["account_id"] == cmd["account_id"]]
            for order in selected:
                cancel(order, "MARKET_CLOSED" if kind == "Close" else cmd.get("reason", "USER_CANCEL"))
            self.orders = [o for o in self.orders if o["remaining"]]
            if kind == "Close":
                self.mode = "CLOSED"
        elif kind in ("Suspend", "Resume"):
            expected = "OPEN" if kind == "Suspend" else "SUSPENDED"
            if self.mode != expected:
                tr["result"] = "INVALID_TRANSITION"
            else:
                self.mode = "SUSPENDED" if kind == "Suspend" else "OPEN"
        elif kind != "Snapshot":
            raise ValueError("INVALID_COMMAND")

        tr["postings"].extend(fees)
        for order in touched.values():
            entries, holds = [], []
            targets = {"SEDI": checked(order["remaining"] * order["limit"]) if order["side"] == "BUY" else 0}
            if order["remaining"] and not order["fee_paid"]:
                targets["SEDI"] += 1
            if order["side"] == "SELL":
                targets[order["outcome"] + ":" + p["market_id"]] = order["remaining"]
            for asset, target in targets.items():
                share = asset != "SEDI"
                stem = "shares" if share else "sedi"
                remaining = order[stem + "_original"] - order[stem + "_consumed"] - order[stem + "_released"]
                release = remaining - target
                if release < 0:
                    raise ValueError("HOLD_EXCEEDED")
                if release:
                    hold = order["share_hold_id" if share else "sedi_hold_id"]
                    entries.extend((entry(owner(order), asset, -release, hold), entry(owner(order), asset, release)))
                    holds.append({"op": "release", "hold_id": hold, "owner": owner(order), "asset_key": asset, "amount": release})
                    order[stem + "_released"] = checked(order[stem + "_released"] + release)
            if entries:
                tr["postings"].append(tx(f"release:{order['id']}:{cmd['seq']}", "ORDER_RELEASE", "order", order["id"], entries, holds))
            status = "PARTIAL" if order["remaining"] and order["filled"] else "OPEN"
            if not order["remaining"]:
                status = "CANCELLED" if order["cancelled"] else "FILLED"
            tr["order_updates"].append({"order": copy.deepcopy(order), "status": status,
                                        "fee_charged_now": not original_fee[order["id"]] and order["fee_paid"],
                                        "cancel_reason": reasons.get(order["id"], "")})
        if incoming and incoming["remaining"]:
            tr["rested"] = copy.deepcopy(incoming)
        tr["mode"] = self.mode
        after = self.levels()
        for side, price in sorted(set(before) | set(after), key=lambda k: (0 if k[0] == "bid" else 1, k[1])):
            if before.get((side, price), 0) != after.get((side, price), 0):
                tr["book_deltas"].append({"side": side, "yes_price": price, "new_level_qty": after.get((side, price), 0)})
        return tr

    def apply(self, plan: Plan):
        self.apply_transition(plan.transition, plan.expected_snapshot)

    def apply_transition(self, t: dict, expected_snapshot=None):
        if t["base_seq"] != self.last_seq or t["prev_hash"] != self.state_hash or t["seq"] != self.last_seq + 1:
            raise ValueError("STALE_TRANSITION")
        expected = hashlib.sha256(bytes.fromhex(self.state_hash) + transition_bytes(t)).hexdigest()
        if expected != t["state_hash"]:
            raise ValueError("TRANSITION_HASH_MISMATCH")
        candidate = copy.deepcopy(self)
        for update in t["order_updates"]:
            order = copy.deepcopy(update["order"])
            candidate.orders = [old for old in candidate.orders if old["id"] != order["id"]]
            if order["remaining"]:
                candidate.orders.append(order)
        if t["supply_delta"]["yes"] != t["supply_delta"]["no"]:
            raise ValueError("INVALID_SUPPLY")
        candidate.pairs = checked(candidate.pairs + t["supply_delta"]["yes"])
        candidate.collateral = checked(candidate.collateral + t["collateral_delta"])
        candidate.mode = t["mode"]
        candidate.last_seq = t["seq"]
        candidate.state_hash = t["state_hash"]
        if t["last_price"] is not None:
            candidate.last_price = t["last_price"]
        candidate.verify()
        if expected_snapshot is not None and candidate.snapshot() != expected_snapshot:
            raise ValueError("ORACLE_APPLY_MISMATCH")
        if "full_state_hash" in t and candidate.full_hash() != t["full_state_hash"]:
            raise ValueError("SNAPSHOT_HASH_MISMATCH")
        self.__dict__ = candidate.__dict__

    @classmethod
    def from_snapshot(cls, snapshot):
        restored = cls(snapshot["policy"], snapshot["pairs"])
        restored.orders = copy.deepcopy(snapshot["orders"])
        for key in ("mode", "last_seq", "state_hash", "last_price", "collateral"):
            setattr(restored, key, snapshot[key])
        restored.verify()
        return restored

    def verify(self):
        if self.pairs < 0 or self.collateral != checked(self.policy["V"] * self.pairs):
            raise ValueError("INVALID_SUPPLY")
        seen = set()
        for order in self.orders:
            if order["id"] in seen or order["remaining"] <= 0:
                raise ValueError("INVALID_BOOK")
            seen.add(order["id"])
            if order["qty"] != order["remaining"] + order["filled"] + order["cancelled"]:
                raise ValueError("INVALID_QUANTITY")
            sedi = order["sedi_original"] - order["sedi_consumed"] - order["sedi_released"]
            expected = order["remaining"] * order["limit"] if order["side"] == "BUY" else 0
            if not order["fee_paid"]:
                expected += 1
            if sedi != expected or (order["side"] == "SELL" and
                    order["shares_original"] - order["shares_consumed"] - order["shares_released"] != order["remaining"]):
                raise ValueError("INVALID_HOLD")
        bids = [price for (side, price) in self.levels() if side == "bid"]
        asks = [price for (side, price) in self.levels() if side == "ask"]
        if bids and asks and max(bids) >= min(asks):
            raise ValueError("CROSSED_BOOK")
        for outcome in ("YES", "NO"):
            reserved = sum(o["remaining"] for o in self.orders if o["side"] == "SELL" and o["outcome"] == outcome)
            if reserved > self.pairs:
                raise ValueError("INVALID_SUPPLY")


def make_order(policy, seq, number, account, outcome, side, price, qty, tif="GTC", group="", owner_kind="user"):
    uuid = lambda value: f"00000000-0000-4000-a000-{value:012d}"
    return dict(id=uuid(number), account_id=uuid(account), owner_kind=owner_kind, owner_group=group,
                outcome=outcome, side=side, limit=price, qty=qty, remaining=qty, tif=tif, accepted_seq=seq,
                fee_paid=False, sedi_hold_id=uuid(100000000 + 2 * number),
                share_hold_id=uuid(100000001 + 2 * number) if side == "SELL" else "",
                sedi_original=checked(price * qty + 1) if side == "BUY" else 1, sedi_consumed=0, sedi_released=0,
                shares_original=qty if side == "SELL" else 0, shares_consumed=0, shares_released=0, filled=0, cancelled=0)
