package main

import (
	"crypto/sha256"
	"math"
)

func sameIdentity(a, b Order) bool {
	return a.Id == b.Id && a.AccountId == b.AccountId && a.OwnerKind == b.OwnerKind && a.OwnerGroup == b.OwnerGroup && a.Outcome == b.Outcome && a.Side == b.Side && a.Limit == b.Limit && a.Qty == b.Qty && a.Tif == b.Tif && a.AcceptedSeq == b.AcceptedSeq && a.SediHoldId == b.SediHoldId && a.ShareHoldId == b.ShareHoldId && a.SediOriginal == b.SediOriginal && a.SharesOriginal == b.SharesOriginal
}
func validOrder(p Policy, o Order) bool {
	if !validUUID(o.Id) || !validUUID(o.AccountId) || !validUUID(o.SediHoldId) || (o.OwnerGroup != "" && !validUUID(o.OwnerGroup)) {
		return false
	}
	if (o.OwnerKind != "user" && o.OwnerKind != "bot") || (o.Outcome != "YES" && o.Outcome != "NO") || (o.Side != "BUY" && o.Side != "SELL") || (o.Tif != "GTC" && o.Tif != "IOC") {
		return false
	}
	if o.Limit < p.Min || o.Limit > p.Max || o.Limit%p.Tick != 0 || o.Qty < 1 || o.Qty > p.MaxQty || o.Remaining < 0 || o.Filled < 0 || o.Cancelled < 0 || o.AcceptedSeq < 1 {
		return false
	}
	if o.Remaining > o.Qty || o.Filled > o.Qty-o.Remaining || o.Cancelled != o.Qty-o.Remaining-o.Filled || o.FeePaid != (o.Filled > 0) {
		return false
	}
	if o.SediOriginal < 0 || o.SediConsumed < 0 || o.SediReleased < 0 || o.SediConsumed > o.SediOriginal || o.SediReleased > o.SediOriginal-o.SediConsumed || o.SharesOriginal < 0 || o.SharesConsumed < 0 || o.SharesReleased < 0 || o.SharesConsumed > o.SharesOriginal || o.SharesReleased > o.SharesOriginal-o.SharesConsumed {
		return false
	}
	if o.Qty > math.MaxInt64/o.Limit {
		return false
	}
	notional := o.Qty * o.Limit
	if notional < p.MinNotional {
		return false
	}
	original, target := int64(1), int64(0)
	if o.Side == "BUY" {
		if notional == math.MaxInt64 {
			return false
		}
		original = notional + 1
		target = o.Remaining * o.Limit
		if o.SharesOriginal != 0 || o.SharesConsumed != 0 || o.SharesReleased != 0 {
			return false
		}
	} else if !validUUID(o.ShareHoldId) || o.SharesOriginal != o.Qty || o.SharesConsumed != o.Filled || o.SharesOriginal-o.SharesConsumed-o.SharesReleased != o.Remaining {
		return false
	}
	if o.Remaining > 0 && !o.FeePaid {
		target++
	}
	return o.SediOriginal == original && o.SediOriginal-o.SediConsumed-o.SediReleased == target
}
func validateApply(b *Book, w *Workspace) string {
	t := w.T
	if !w.Ready {
		return "NO_PLAN"
	}
	if t.BaseSeq != b.Seq || b.Seq == math.MaxInt64 || t.Seq != b.Seq+1 || w.Prev != b.Hash {
		return "STALE_TRANSITION"
	}
	if t.Mode != "OPEN" && t.Mode != "SUSPENDED" && t.Mode != "CLOSED" {
		return "INVALID_TRANSITION"
	}
	if t.LastPrice != 0 && (t.LastPrice < b.Policy.Min || t.LastPrice > b.Policy.Max || t.LastPrice%b.Policy.Tick != 0) {
		return "INTERNAL_PRICE_OUT_OF_BAND"
	}
	pairs := w.add(b.Pairs, t.Supply)
	if pairs < 0 {
		return "INVALID_SUPPLY"
	}
	collateral := w.mul(pairs, b.Policy.V)
	if w.Err != "" {
		return w.Err
	}
	if collateral-b.Collateral != t.Collateral {
		return "INVALID_SUPPLY"
	}
	ry, rn := b.ReservedYes, b.ReservedNo
	terminals, incoming, lastTerminal := 0, -1, -1
	for s := 0; s < 2; s++ {
		for p := int64(0); p <= b.Policy.V; p++ {
			w.Totals[s*int(b.Policy.V+1)+int(p)] = b.level(s == 0, p).Total
		}
	}
	for i := 0; i < t.UpdateCount; i++ {
		u := w.Updates[i]
		o := u.Order
		if !validOrder(b.Policy, o) {
			return "INVALID_ORDER_FACTS"
		}
		before := int64(0)
		if u.Slot >= 0 {
			if u.Slot >= len(b.Slots) {
				return "STALE_SLOT"
			}
			old := b.Slots[u.Slot]
			if !old.Active || old.Generation != u.Generation || !sameIdentity(old.Order, o) || w.SlotEpoch[u.Slot] != w.Epoch || w.SlotUpdate[u.Slot] != i {
				return "STALE_SLOT"
			}
			if o.Remaining > old.Order.Remaining || o.Filled < old.Order.Filled || o.Cancelled < old.Order.Cancelled || o.SediConsumed < old.Order.SediConsumed || o.SediReleased < old.Order.SediReleased || o.SharesConsumed < old.Order.SharesConsumed || o.SharesReleased < old.Order.SharesReleased {
				return "INVALID_ORDER_FACTS"
			}
			before = old.Order.Remaining
			if o.Remaining == 0 {
				terminals++
				lastTerminal = u.Slot
			}
		} else {
			if incoming >= 0 || (t.Kind != "Place" && t.Kind != "RejectPlace") || o.AcceptedSeq != t.Seq || b.find(o.Id) >= 0 {
				return "INVALID_ORDER_FACTS"
			}
			incoming = i
		}
		at := int(price(b.Policy, o))
		if !isBid(o) {
			at += int(b.Policy.V + 1)
		}
		total := w.add(w.Totals[at]-before, o.Remaining)
		if total < 0 {
			return "INVALID_LEVEL"
		}
		w.Totals[at] = total
		if o.Side == "SELL" {
			if o.Outcome == "YES" {
				ry = w.add(ry-before, o.Remaining)
			} else {
				rn = w.add(rn-before, o.Remaining)
			}
		}
	}
	if w.Err != "" {
		return w.Err
	}
	if ry < 0 || rn < 0 || ry > pairs || rn > pairs || ry != t.ReservedYes || rn != t.ReservedNo || incoming != t.Incoming {
		return "INVALID_SUPPLY"
	}
	if t.Kind == "RejectPlace" {
		if incoming < 0 || t.UpdateCount != 1 || t.FillCount != 0 || t.Supply != 0 || t.Collateral != 0 || t.DeltaCount != 0 || t.Mode != b.Mode || !rejectionReason(t.Decision) {
			return "INVALID_REJECTION"
		}
		u := w.Updates[incoming]
		if u.Order.Filled != 0 || u.Order.Remaining != 0 || u.Order.Cancelled != u.Order.Qty || u.Fee || u.Reason != t.Decision || u.Status != "CANCELLED" {
			return "INVALID_REJECTION"
		}
	}
	if t.FillCount > 0 && incoming < 0 {
		return "INVALID_FILL"
	}
	if t.Mode == "CLOSED" && b.Active-terminals > 0 {
		return "INVALID_TRANSITION"
	}
	for i := 0; i < t.FillCount; i++ {
		f := w.Fills[i]
		taker := w.Updates[incoming].Order
		slot := b.find(f.Maker)
		if slot < 0 || w.SlotEpoch[slot] != w.Epoch || f.Taker != taker.Id || f.Qty <= 0 || f.Price < b.Policy.Min || f.Price > b.Policy.Max || f.Price%b.Policy.Tick != 0 {
			return "INVALID_FILL"
		}
		maker := b.Slots[slot].Order
		if maker.AccountId == taker.AccountId || (maker.OwnerGroup != "" && maker.OwnerGroup == taker.OwnerGroup) || price(b.Policy, maker) != f.Price || isBid(maker) == isBid(taker) {
			return "INVALID_FILL"
		}
		own := f.Price
		if taker.Outcome == "NO" {
			own = b.Policy.V - own
		}
		if (taker.Side == "BUY" && own > taker.Limit) || (taker.Side == "SELL" && own < taker.Limit) {
			return "INVALID_FILL"
		}
		bid, ask := maker, taker
		if isBid(taker) {
			bid, ask = taker, maker
		}
		mode := "MERGE"
		if bid.Side == "BUY" && ask.Side == "SELL" {
			mode = "TRANSFER_YES"
		}
		if bid.Side == "SELL" && ask.Side == "BUY" {
			mode = "TRANSFER_NO"
		}
		if bid.Side == "BUY" && ask.Side == "BUY" {
			mode = "MINT"
		}
		if f.Mode != mode {
			return "INVALID_FILL"
		}
	}
	resting := incoming >= 0 && w.Updates[incoming].Order.Remaining > 0
	if resting {
		slot := lastTerminal
		if b.FreeCount > 0 {
			slot = b.Free[b.FreeCount-1]
		}
		if slot < 0 || slot != t.RestSlot || b.Slots[slot].Generation == math.MaxInt64 {
			return "NEED_CAPACITY"
		}
		o := w.Updates[incoming].Order
		if o.Tif != "GTC" || t.Mode != "OPEN" {
			return "INVALID_ORDER_FACTS"
		}
	} else if t.RestSlot != -1 {
		return "INVALID_TRANSITION"
	}
	di := 0
	for s := 0; s < 2; s++ {
		for p := b.Policy.Min; p <= b.Policy.Max; p++ {
			total := w.Totals[s*int(b.Policy.V+1)+int(p)]
			if total == b.level(s == 0, p).Total {
				continue
			}
			if di >= t.DeltaCount {
				return "INVALID_LEVEL"
			}
			d := w.Deltas[di]
			name := "bid"
			if s == 1 {
				name = "ask"
			}
			if d.Side != name || d.Price != p || d.Total != total {
				return "INVALID_LEVEL"
			}
			di++
		}
	}
	if di != t.DeltaCount {
		return "INVALID_LEVEL"
	}
	for i := 0; i < t.PostingCount; i++ {
		p := w.Postings[i]
		if p.KeyStart < 0 || p.KeySize < 1 || p.KeyStart > w.Keys.Pos || p.KeySize > w.Keys.Pos-p.KeyStart || p.EntryStart < 0 || p.EntryCount < 1 || p.EntryStart > t.EntryCount || p.EntryCount > t.EntryCount-p.EntryStart || p.HoldStart < 0 || p.HoldCount < 0 || p.HoldStart > t.HoldCount || p.HoldCount > t.HoldCount-p.HoldStart {
			return "INVALID_POSTING"
		}
		sedi, yes, no := int64(0), int64(0), int64(0)
		for j := p.EntryStart; j < p.EntryStart+p.EntryCount; j++ {
			e := w.Entries[j]
			if e.Delta == 0 {
				return "ZERO_ENTRY"
			}
			switch e.Asset {
			case "SEDI":
				sedi = w.add(sedi, e.Delta)
			case b.YesAsset:
				yes = w.add(yes, e.Delta)
			case b.NoAsset:
				no = w.add(no, e.Delta)
			default:
				return "INVALID_ASSET"
			}
		}
		if w.Err != "" {
			return w.Err
		}
		if sedi != 0 || yes != 0 || no != 0 {
			return "UNBALANCED_POSTING"
		}
	}
	w.encode(b)
	if w.Bytes.Failed {
		return "NEED_CAPACITY"
	}
	if sha256.Sum256(w.Bytes.Data[:w.Bytes.Pos]) != w.Next {
		return "TRANSITION_HASH_MISMATCH"
	}
	return ""
}
func Apply(b *Book, w *Workspace) string {
	if e := validateApply(b, w); e != "" {
		return e
	}
	t := w.T
	reserve := t.RestSlot >= 0 && b.FreeCount > 0
	if reserve {
		b.FreeCount--
	}
	for i := 0; i < t.UpdateCount; i++ {
		u := w.Updates[i]
		if u.Slot < 0 {
			continue
		}
		if u.Order.Remaining == 0 {
			b.remove(u.Slot)
		} else {
			s := &b.Slots[u.Slot]
			b.level(isBid(u.Order), price(b.Policy, u.Order)).Total += u.Order.Remaining - s.Order.Remaining
			s.Order = u.Order
		}
	}
	if t.RestSlot >= 0 {
		if !reserve {
			b.FreeCount--
			if b.Free[b.FreeCount] != t.RestSlot {
				panic("invalid reserved slot")
			}
		}
		b.insert(t.RestSlot, w.Updates[t.Incoming].Order)
	}
	for b.BestBid > 0 && b.Bids[b.BestBid].Total == 0 {
		b.BestBid--
	}
	for b.BestAsk < int(b.Policy.V) && b.Asks[b.BestAsk].Total == 0 {
		b.BestAsk++
	}
	b.Pairs += t.Supply
	b.Collateral += t.Collateral
	b.ReservedYes = t.ReservedYes
	b.ReservedNo = t.ReservedNo
	b.Mode = t.Mode
	b.Seq = t.Seq
	b.Hash = w.Next
	if t.LastPrice != 0 {
		b.LastPrice = t.LastPrice
	}
	w.Ready = false
	return ""
}
func Verify(b *Book, w *Workspace) string {
	savedError := w.Err
	w.Err = ""
	defer func() { w.Err = savedError }()
	if b.Pairs < 0 || b.Pairs > math.MaxInt64/b.Policy.V || b.Collateral != b.Pairs*b.Policy.V {
		return "INVALID_SUPPLY"
	}
	seen := w.Seen
	for i := range seen {
		seen[i] = 0
	}
	count, ry, rn, bestBid, bestAsk := 0, int64(0), int64(0), 0, int(b.Policy.V)
	for s := 0; s < 2; s++ {
		for p := int64(0); p <= b.Policy.V; p++ {
			l := b.level(s == 0, p)
			at, prev, total := l.Head, -1, int64(0)
			for at >= 0 {
				if at >= len(b.Slots) || seen[at] != 0 {
					return "INVALID_QUEUE"
				}
				seen[at] = 1
				slot := b.Slots[at]
				o := slot.Order
				if !slot.Active || slot.Prev != prev || o.Remaining < 1 || o.AcceptedSeq > b.Seq || o.Tif != "GTC" || isBid(o) != (s == 0) || price(b.Policy, o) != p || !validOrder(b.Policy, o) {
					return "INVALID_QUEUE"
				}
				if prev >= 0 {
					older := b.Slots[prev].Order
					if older.AcceptedSeq > o.AcceptedSeq || (older.AcceptedSeq == o.AcceptedSeq && older.Id >= o.Id) {
						return "INVALID_PRIORITY"
					}
				}
				if b.find(o.Id) != at {
					return "INVALID_INDEX"
				}
				total = w.add(total, o.Remaining)
				if o.Side == "SELL" {
					if o.Outcome == "YES" {
						ry = w.add(ry, o.Remaining)
					} else {
						rn = w.add(rn, o.Remaining)
					}
				}
				count++
				prev = at
				at = slot.Next
			}
			if prev != l.Tail || total != l.Total {
				return "INVALID_LEVEL"
			}
			if total > 0 {
				if s == 0 {
					bestBid = int(p)
				} else if int(p) < bestAsk {
					bestAsk = int(p)
				}
			}
		}
	}
	for _, at := range b.Free[:b.FreeCount] {
		if at < 0 || at >= len(b.Slots) || seen[at] != 0 || b.Slots[at].Active {
			return "INVALID_FREE_LIST"
		}
		seen[at] = 2
	}
	for _, value := range seen {
		if value == 0 {
			return "UNREACHABLE_SLOT"
		}
	}
	if count != b.Active || count != len(b.Slots)-b.FreeCount || bestBid != b.BestBid || bestAsk != b.BestAsk || bestBid >= bestAsk || (b.Mode == "CLOSED" && count > 0) {
		return "INVALID_BOOK"
	}
	if ry != b.ReservedYes || rn != b.ReservedNo || ry > b.Pairs || rn > b.Pairs {
		return "INVALID_SUPPLY"
	}
	return w.Err
}
