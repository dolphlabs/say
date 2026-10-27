import copy
import unittest

from exchange import Exchange, make_order


def policy(v=100):
    return dict(market_id="00000000-0000-4000-a000-000000000900", season_id="00000000-0000-4000-a000-000000000901",
                V=v, min_price=1, max_price=v-1, tick=1, max_order_qty=10000, min_order_notional=2)


class OracleTests(unittest.TestCase):
    def place(self, state, number, account, outcome, side, price, qty, tif="GTC", group=""):
        seq = state.last_seq + 1
        order = make_order(state.policy, seq, number, account, outcome, side, price, qty, tif, group)
        planned = state.plan(dict(seq=seq, ref=order["id"], kind="Place", order=order))
        state.apply(planned)
        return planned.transition

    def test_transfer_and_price_improvement(self):
        state = Exchange(policy(), pairs=1)
        self.place(state, 1, 11, "YES", "SELL", 60, 1)
        tr = self.place(state, 2, 12, "YES", "BUY", 75, 1)
        self.assertEqual([(f["mode"], f["yes_price"], f["qty"]) for f in tr["fills"]], [("TRANSFER_YES", 60, 1)])
        self.assertEqual([p["kind"] for p in tr["postings"]], ["FILL", "FEE", "FEE", "ORDER_RELEASE"])
        self.assertEqual(tr["postings"][-1]["holds"][0]["amount"], 15)
        self.assertEqual(state.pairs, 1)

    def test_mint_and_merge_conserve(self):
        state = Exchange(policy())
        self.place(state, 1, 11, "NO", "BUY", 45, 1)
        minted = self.place(state, 2, 12, "YES", "BUY", 70, 1)
        self.assertEqual((state.pairs, state.collateral), (1, 100))
        self.assertEqual(minted["fills"][0]["mode"], "MINT")
        self.place(state, 3, 11, "NO", "SELL", 40, 1)
        merged = self.place(state, 4, 12, "YES", "SELL", 50, 1)
        self.assertEqual(merged["fills"][0]["yes_price"], 60)
        self.assertEqual((state.pairs, state.collateral), (0, 0))

    def test_fifo_across_modes_and_fee_once(self):
        state = Exchange(policy(), pairs=3)
        self.place(state, 1, 11, "YES", "SELL", 58, 3)
        self.place(state, 2, 12, "NO", "BUY", 42, 5)
        first = self.place(state, 3, 13, "YES", "BUY", 60, 6)
        self.assertEqual([(f["mode"], f["qty"]) for f in first["fills"]], [("TRANSFER_YES", 3), ("MINT", 3)])
        second = self.place(state, 4, 14, "YES", "BUY", 58, 2)
        self.assertEqual(sum(p["kind"] == "FEE" for p in second["postings"]), 1)
        self.assertFalse(state.orders)

    def test_self_prevention_and_ioc(self):
        state = Exchange(policy(), pairs=4)
        group = "00000000-0000-4000-a000-000000000777"
        self.place(state, 1, 11, "YES", "SELL", 58, 4, group=group)
        prevented = self.place(state, 2, 12, "YES", "BUY", 58, 10, group=group)
        self.assertFalse(prevented["fills"])
        self.assertEqual(prevented["order_updates"][0]["cancel_reason"], "SELF_TRADE_PREVENTED")
        ioc = self.place(state, 3, 13, "YES", "BUY", 58, 10, "IOC")
        self.assertEqual(ioc["order_updates"][1]["order"]["cancelled"], 6)

    def test_plan_discard_replay_and_tamper(self):
        state = Exchange(policy())
        order = make_order(state.policy, 1, 1, 11, "YES", "BUY", 40, 2)
        before = state.snapshot()
        planned = state.plan(dict(seq=1, ref=order["id"], kind="Place", order=order))
        self.assertEqual(state.snapshot(), before)
        state.apply(planned)
        restored = Exchange.from_snapshot(before)
        restored.apply_transition(planned.transition)
        self.assertEqual(restored.full_hash(), state.full_hash())
        with self.assertRaisesRegex(ValueError, "STALE_TRANSITION"):
            state.apply(planned)
        tampered = copy.deepcopy(planned.transition)
        tampered["seq"] = 2
        with self.assertRaises(ValueError):
            Exchange.from_snapshot(before).apply_transition(tampered)


if __name__ == "__main__":
    unittest.main()
