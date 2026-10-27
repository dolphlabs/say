package main

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"math"
	"strconv"
)

type Policy struct {
	MarketID    string `json:"market_id"`
	SeasonID    string `json:"season_id"`
	V           int64  `json:"V"`
	Min         int64  `json:"min_price"`
	Max         int64  `json:"max_price"`
	Tick        int64  `json:"tick"`
	MaxQty      int64  `json:"max_order_qty"`
	MinNotional int64  `json:"min_order_notional"`
}
type Order struct {
	Id             string `json:"id"`
	AccountId      string `json:"account_id"`
	OwnerKind      string `json:"owner_kind"`
	OwnerGroup     string `json:"owner_group"`
	Outcome        string `json:"outcome"`
	Side           string `json:"side"`
	Limit          int64  `json:"limit"`
	Qty            int64  `json:"qty"`
	Remaining      int64  `json:"remaining"`
	Tif            string `json:"tif"`
	AcceptedSeq    int64  `json:"accepted_seq"`
	FeePaid        bool   `json:"fee_paid"`
	SediHoldId     string `json:"sedi_hold_id"`
	ShareHoldId    string `json:"share_hold_id"`
	SediOriginal   int64  `json:"sedi_original"`
	SediConsumed   int64  `json:"sedi_consumed"`
	SediReleased   int64  `json:"sedi_released"`
	SharesOriginal int64  `json:"shares_original"`
	SharesConsumed int64  `json:"shares_consumed"`
	SharesReleased int64  `json:"shares_released"`
	Filled         int64  `json:"filled"`
	Cancelled      int64  `json:"cancelled"`
}
type Command struct {
	Kind      string `json:"kind"`
	Seq       int64  `json:"seq"`
	Ref       string `json:"ref"`
	Order     Order  `json:"order"`
	OrderID   string `json:"order_id"`
	AccountID string `json:"account_id"`
	System    bool   `json:"system"`
	Reason    string `json:"reason"`
}
type Level struct {
	Head, Tail int
	Total      int64
}
type Slot struct {
	Order      Order
	Prev, Next int
	Generation int64
	Active     bool
}
type Bucket struct{ Slot, Home int }
type Fill struct {
	Mode, Maker, Taker string
	Qty, Price         int64
}
type Update struct {
	Order          Order
	Slot           int
	Generation     int64
	Fee            bool
	Reason, Status string
}
type Entry struct {
	Kind, Owner, Asset, Bucket string
	Delta                      int64
	Hold                       string
}
type Hold struct {
	Op, ID, Kind, Owner, Asset string
	Amount                     int64
}
type Posting struct {
	KeyStart, KeySize                            int
	Kind, RefType, RefID                         string
	EntryStart, EntryCount, HoldStart, HoldCount int
}
type Delta struct {
	Side         string
	Price, Total int64
}
type Book struct {
	Policy                                                     Policy
	Mode                                                       string
	Seq, LastPrice, Pairs, Collateral, ReservedYes, ReservedNo int64
	Active, BestBid, BestAsk                                   int
	Bids, Asks                                                 []Level
	Slots                                                      []Slot
	Index                                                      []Bucket
	Free                                                       []int
	FreeCount                                                  int
	Hash                                                       [32]byte
	YesAsset, NoAsset, CollateralOwner, SharesOwner            string
}
type Transition struct {
	BaseSeq, Seq                                                            int64
	Ref, Kind, Decision, Mode                                               string
	FillCount, UpdateCount, PostingCount, EntryCount, HoldCount, DeltaCount int
	Supply, Collateral, LastPrice, ReservedYes, ReservedNo                  int64
	Incoming, RestSlot                                                      int
}
type Writer struct {
	Data   []byte
	Pos    int
	Failed bool
}

func writer(capacity int) Writer { return Writer{Data: make([]byte, capacity)} }
func (w *Writer) reset()         { w.Pos = 0; w.Failed = false }
func (w *Writer) raw(v string) {
	if w.Failed {
		return
	}
	if len(v) > len(w.Data)-w.Pos {
		w.Failed = true
		return
	}
	w.Pos += copy(w.Data[w.Pos:], v)
}
func (w *Writer) span(v []byte) {
	if w.Failed {
		return
	}
	if len(v) > len(w.Data)-w.Pos {
		w.Failed = true
		return
	}
	w.Pos += copy(w.Data[w.Pos:], v)
}
func (w *Writer) decimal(v int64) {
	var buf [20]byte
	out := strconv.AppendInt(buf[:0], v, 10)
	w.span(out)
}
func (w *Writer) text(v string) { w.decimal(int64(len(v))); w.raw(":"); w.raw(v) }
func (w *Writer) number(v int64) {
	var buf [20]byte
	out := strconv.AppendInt(buf[:0], v, 10)
	w.decimal(int64(len(out)))
	w.raw(":")
	w.span(out)
}
func (w *Writer) boolean(v bool) {
	if v {
		w.raw("1:1")
	} else {
		w.raw("1:0")
	}
}
func (w *Writer) hash(h [32]byte) { var buf [64]byte; hex.Encode(buf[:], h[:]); w.span(buf[:]) }
func writePolicy(w *Writer, p Policy) {
	w.text(p.MarketID)
	w.text(p.SeasonID)
	w.number(p.V)
	w.number(p.Min)
	w.number(p.Max)
	w.number(p.Tick)
	w.number(p.MaxQty)
	w.number(p.MinNotional)
}
func writeOrder(w *Writer, o Order) {
	w.text(o.Id)
	w.text(o.AccountId)
	w.text(o.OwnerKind)
	w.text(o.OwnerGroup)
	w.text(o.Outcome)
	w.text(o.Side)
	w.number(o.Limit)
	w.number(o.Qty)
	w.number(o.Remaining)
	w.text(o.Tif)
	w.number(o.AcceptedSeq)
	w.boolean(o.FeePaid)
	w.text(o.SediHoldId)
	w.text(o.ShareHoldId)
	w.number(o.SediOriginal)
	w.number(o.SediConsumed)
	w.number(o.SediReleased)
	w.number(o.SharesOriginal)
	w.number(o.SharesConsumed)
	w.number(o.SharesReleased)
	w.number(o.Filled)
	w.number(o.Cancelled)
}
func isBid(o Order) bool { return (o.Side == "BUY") == (o.Outcome == "YES") }
func price(p Policy, o Order) int64 {
	if o.Outcome == "YES" {
		return o.Limit
	}
	return p.V - o.Limit
}
func side(o Order) string {
	if isBid(o) {
		return "bid"
	}
	return "ask"
}
func validUUID(s string) bool {
	if len(s) != 36 {
		return false
	}
	for i, c := range []byte(s) {
		if i == 8 || i == 13 || i == 18 || i == 23 {
			if c != '-' {
				return false
			}
		} else if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
			return false
		}
	}
	return true
}
func NewBook(p Policy, capacity int, pairs int64) (*Book, error) {
	if !validUUID(p.MarketID) || !validUUID(p.SeasonID) || p.V < 10 || p.V > 1000 || p.Min < 1 || p.Min > p.Max || p.Max >= p.V || p.Min+p.Max != p.V || p.Tick <= 0 || p.Min%p.Tick != 0 || (p.Max-p.Min)%p.Tick != 0 || p.V%p.Tick != 0 || p.MaxQty <= 0 || p.MinNotional != 2 || capacity < 1 || capacity > 100000 {
		return nil, fmt.Errorf("INVALID_POLICY")
	}
	if pairs < 0 || pairs > math.MaxInt64/p.V {
		return nil, fmt.Errorf("INVALID_SUPPLY")
	}
	buckets := 2
	for buckets < capacity*2 {
		buckets *= 2
	}
	b := &Book{Policy: p, Mode: "OPEN", Pairs: pairs, Collateral: pairs * p.V, Bids: make([]Level, p.V+1), Asks: make([]Level, p.V+1), Slots: make([]Slot, capacity), Index: make([]Bucket, buckets), Free: make([]int, capacity), FreeCount: capacity, BestAsk: int(p.V), YesAsset: "YES:" + p.MarketID, NoAsset: "NO:" + p.MarketID, CollateralOwner: "system:collateral:" + p.MarketID, SharesOwner: "system:shares:" + p.MarketID}
	for i := range b.Bids {
		b.Bids[i] = Level{Head: -1, Tail: -1}
		b.Asks[i] = b.Bids[i]
	}
	for i := range b.Index {
		b.Index[i].Slot = -1
	}
	for i := range b.Slots {
		b.Slots[i].Prev = -1
		b.Slots[i].Next = -1
		b.Free[i] = capacity - i - 1
	}
	w := writer(512)
	w.text("say.genesis.v1")
	writePolicy(&w, p)
	w.number(pairs)
	w.number(b.Collateral)
	b.Hash = sha256.Sum256(w.Data[:w.Pos])
	return b, nil
}
func (b *Book) home(id string) int {
	h := 0
	for i := 0; i < len(id); i++ {
		h = (h*257 + int(id[i])) & (len(b.Index) - 1)
	}
	return h
}
func (b *Book) find(id string) int {
	if len(id) != 36 {
		return -1
	}
	at := b.home(id)
	for i := 0; i < len(b.Index); i++ {
		slot := b.Index[at].Slot
		if slot < 0 {
			return -1
		}
		if b.Slots[slot].Order.Id == id {
			return slot
		}
		at = (at + 1) & (len(b.Index) - 1)
	}
	return -1
}
func (b *Book) level(bid bool, p int64) *Level {
	if bid {
		return &b.Bids[p]
	}
	return &b.Asks[p]
}
func (b *Book) insert(at int, o Order) {
	level := b.level(isBid(o), price(b.Policy, o))
	if level.Tail >= 0 {
		b.Slots[level.Tail].Next = at
	} else {
		level.Head = at
	}
	b.Slots[at] = Slot{Order: o, Prev: level.Tail, Next: -1, Generation: b.Slots[at].Generation + 1, Active: true}
	level.Tail = at
	level.Total += o.Remaining
	home := b.home(o.Id)
	pos := home
	for b.Index[pos].Slot >= 0 {
		pos = (pos + 1) & (len(b.Index) - 1)
	}
	b.Index[pos] = Bucket{Slot: at, Home: home}
	b.Active++
	p := int(price(b.Policy, o))
	if isBid(o) && p > b.BestBid {
		b.BestBid = p
	}
	if !isBid(o) && p < b.BestAsk {
		b.BestAsk = p
	}
}
func (b *Book) remove(at int) {
	s := b.Slots[at]
	l := b.level(isBid(s.Order), price(b.Policy, s.Order))
	if s.Prev >= 0 {
		b.Slots[s.Prev].Next = s.Next
	} else {
		l.Head = s.Next
	}
	if s.Next >= 0 {
		b.Slots[s.Next].Prev = s.Prev
	} else {
		l.Tail = s.Prev
	}
	l.Total -= s.Order.Remaining
	mask := len(b.Index) - 1
	hole := b.home(s.Order.Id)
	for b.Index[hole].Slot >= 0 && b.Slots[b.Index[hole].Slot].Order.Id != s.Order.Id {
		hole = (hole + 1) & mask
	}
	for pos := (hole + 1) & mask; b.Index[pos].Slot >= 0; pos = (pos + 1) & mask {
		v := b.Index[pos]
		if ((pos - v.Home) & mask) > ((hole - v.Home) & mask) {
			b.Index[hole] = v
			hole = pos
		}
	}
	b.Index[hole] = Bucket{Slot: -1}
	b.Slots[at] = Slot{Prev: -1, Next: -1, Generation: s.Generation}
	b.Free[b.FreeCount] = at
	b.FreeCount++
	b.Active--
}

type Workspace struct {
	T                Transition
	Ready            bool
	Err              string
	Epoch            int64
	Fills            []Fill
	Updates          []Update
	Postings         []Posting
	Entries          []Entry
	Holds            []Hold
	Deltas           []Delta
	SlotEpoch        []int64
	Seen             []int
	SlotUpdate       []int
	LevelEpoch       []int64
	Totals           []int64
	Keys, Bytes      Writer
	Prev, Next, Full [32]byte
}

func NewWorkspace(b *Book, capacity int) *Workspace {
	return &Workspace{Fills: make([]Fill, capacity), Updates: make([]Update, capacity+1), Postings: make([]Posting, 3*capacity+3), Entries: make([]Entry, 13*capacity+6), Holds: make([]Hold, 5*capacity+3), Deltas: make([]Delta, 2*(b.Policy.V+1)), SlotEpoch: make([]int64, len(b.Slots)), Seen: make([]int, len(b.Slots)), SlotUpdate: make([]int, len(b.Slots)), LevelEpoch: make([]int64, 2*(b.Policy.V+1)), Totals: make([]int64, 2*(b.Policy.V+1)), Keys: writer(240*capacity + 256), Bytes: writer(6000*capacity + 8192)}
}
func (w *Workspace) fail(e string) {
	if w.Err == "" {
		w.Err = e
	}
	w.Ready = false
}
func (w *Workspace) add(a, b int64) int64 {
	if (b > 0 && a > math.MaxInt64-b) || (b < 0 && a < math.MinInt64-b) {
		w.fail("OVERFLOW")
		return 0
	}
	return a + b
}
func (w *Workspace) mul(a, b int64) int64 {
	if a < 0 || b < 0 || (a != 0 && b > math.MaxInt64/a) {
		w.fail("OVERFLOW")
		return 0
	}
	return a * b
}
func (w *Workspace) touch(b *Book, slot int, o Order) int {
	if slot >= 0 && w.SlotEpoch[slot] == w.Epoch {
		return w.SlotUpdate[slot]
	}
	if slot < 0 && w.T.Incoming >= 0 {
		return w.T.Incoming
	}
	at := w.T.UpdateCount
	if at == len(w.Updates) {
		w.fail("NEED_CAPACITY")
		return -1
	}
	w.T.UpdateCount++
	u := Update{Order: o, Slot: slot}
	if slot >= 0 {
		u.Order = b.Slots[slot].Order
		u.Generation = b.Slots[slot].Generation
		w.SlotEpoch[slot] = w.Epoch
		w.SlotUpdate[slot] = at
	} else {
		w.T.Incoming = at
	}
	w.Updates[at] = u
	return at
}
func (w *Workspace) levelChange(b *Book, o Order, delta int64) {
	at := int(price(b.Policy, o))
	if !isBid(o) {
		at += int(b.Policy.V + 1)
	}
	if w.LevelEpoch[at] != w.Epoch {
		w.LevelEpoch[at] = w.Epoch
		w.Totals[at] = b.level(isBid(o), price(b.Policy, o)).Total
	}
	w.Totals[at] = w.add(w.Totals[at], delta)
	if w.Totals[at] < 0 {
		w.fail("INVALID_LEVEL")
	}
}
func (w *Workspace) entry(kind, owner, asset string, delta int64, hold string) {
	if w.Err != "" {
		return
	}
	if w.T.EntryCount == len(w.Entries) {
		w.fail("NEED_CAPACITY")
		return
	}
	if delta == 0 {
		w.fail("ZERO_ENTRY")
		return
	}
	bucket := "free"
	if hold != "" {
		bucket = "held"
	}
	w.Entries[w.T.EntryCount] = Entry{kind, owner, asset, bucket, delta, hold}
	w.T.EntryCount++
}
func (w *Workspace) hold(op string, o Order, asset string, amount int64, id string) {
	if w.Err != "" {
		return
	}
	if w.T.HoldCount == len(w.Holds) {
		w.fail("NEED_CAPACITY")
		return
	}
	w.Holds[w.T.HoldCount] = Hold{op, id, o.OwnerKind, o.AccountId, asset, amount}
	w.T.HoldCount++
}
func (w *Workspace) begin(kind, refType, ref string) Posting {
	return Posting{KeyStart: w.Keys.Pos, Kind: kind, RefType: refType, RefID: ref, EntryStart: w.T.EntryCount, HoldStart: w.T.HoldCount}
}
func (w *Workspace) end(p Posting) {
	if w.Err != "" {
		return
	}
	if w.Keys.Failed || w.T.PostingCount == len(w.Postings) {
		w.fail("NEED_CAPACITY")
		return
	}
	p.KeySize = w.Keys.Pos - p.KeyStart
	p.EntryCount = w.T.EntryCount - p.EntryStart
	p.HoldCount = w.T.HoldCount - p.HoldStart
	w.Postings[w.T.PostingCount] = p
	w.T.PostingCount++
}
func asset(b *Book, o Order) string {
	if o.Outcome == "YES" {
		return b.YesAsset
	}
	return b.NoAsset
}
func (w *Workspace) take(b *Book, at int, share bool, amount int64) {
	if w.Err != "" {
		return
	}
	o := &w.Updates[at].Order
	id, a, available := o.SediHoldId, "SEDI", o.SediOriginal-o.SediConsumed-o.SediReleased
	if share {
		id = o.ShareHoldId
		a = asset(b, *o)
		available = o.SharesOriginal - o.SharesConsumed - o.SharesReleased
	}
	if amount <= 0 || amount > available {
		w.fail("HOLD_EXCEEDED")
		return
	}
	if share {
		o.SharesConsumed += amount
	} else {
		o.SediConsumed += amount
	}
	w.entry(o.OwnerKind, o.AccountId, a, -amount, id)
	w.hold("consume", *o, a, amount, id)
}
func (w *Workspace) fee(at int) {
	u := &w.Updates[at]
	if u.Order.FeePaid {
		return
	}
	if u.Order.SediOriginal-u.Order.SediConsumed-u.Order.SediReleased < 1 {
		w.fail("HOLD_EXCEEDED")
		return
	}
	u.Order.SediConsumed++
	u.Order.FeePaid = true
	u.Fee = true
}
func (w *Workspace) cancel(b *Book, at int, reason string) {
	if at < 0 || w.Err != "" {
		return
	}
	u := &w.Updates[at]
	if u.Slot >= 0 {
		w.levelChange(b, u.Order, -u.Order.Remaining)
	}
	u.Order.Cancelled += u.Order.Remaining
	u.Order.Remaining = 0
	u.Reason = reason
}
func (w *Workspace) fill(b *Book, maker, taker int, x, q int64) {
	if w.T.FillCount == len(w.Fills) {
		w.fail("NEED_CAPACITY")
		return
	}
	bid, ask := taker, maker
	if !isBid(w.Updates[taker].Order) {
		bid, ask = maker, taker
	}
	bo, ao := w.Updates[bid].Order, w.Updates[ask].Order
	mode := "MERGE"
	if bo.Side == "BUY" && ao.Side == "SELL" {
		mode = "TRANSFER_YES"
	}
	if bo.Side == "SELL" && ao.Side == "BUY" {
		mode = "TRANSFER_NO"
	}
	if bo.Side == "BUY" && ao.Side == "BUY" {
		mode = "MINT"
	}
	ya, na := w.mul(x, q), w.mul(b.Policy.V-x, q)
	total := w.add(ya, na)
	kind := mode
	if mode == "TRANSFER_YES" || mode == "TRANSFER_NO" {
		kind = "FILL"
	}
	p := w.begin(kind, "market_command", w.T.Ref)
	w.Keys.raw("fill:")
	w.Keys.raw(b.Policy.MarketID)
	w.Keys.raw(":")
	w.Keys.decimal(w.T.Seq)
	w.Keys.raw(":")
	w.Keys.decimal(int64(w.T.FillCount))
	if kind == "FILL" {
		buyer, seller, amount := bid, ask, ya
		if mode == "TRANSFER_NO" {
			buyer, seller, amount = ask, bid, na
		}
		buy, sell := w.Updates[buyer].Order, w.Updates[seller].Order
		a := asset(b, buy)
		w.take(b, buyer, false, amount)
		w.entry(sell.OwnerKind, sell.AccountId, "SEDI", amount, "")
		w.take(b, seller, true, q)
		w.entry(buy.OwnerKind, buy.AccountId, a, q, "")
	} else if mode == "MINT" {
		w.take(b, bid, false, ya)
		w.take(b, ask, false, na)
		w.entry("system", b.CollateralOwner, "SEDI", total, "")
		w.entry("system", b.SharesOwner, b.YesAsset, -q, "")
		w.entry(bo.OwnerKind, bo.AccountId, b.YesAsset, q, "")
		w.entry("system", b.SharesOwner, b.NoAsset, -q, "")
		w.entry(ao.OwnerKind, ao.AccountId, b.NoAsset, q, "")
	} else {
		w.take(b, ask, true, q)
		w.entry("system", b.SharesOwner, b.YesAsset, q, "")
		w.take(b, bid, true, q)
		w.entry("system", b.SharesOwner, b.NoAsset, q, "")
		w.entry("system", b.CollateralOwner, "SEDI", -total, "")
		w.entry(ao.OwnerKind, ao.AccountId, "SEDI", ya, "")
		w.entry(bo.OwnerKind, bo.AccountId, "SEDI", na, "")
	}
	w.end(p)
	if w.Err != "" {
		return
	}
	if mode == "MINT" || mode == "MERGE" {
		delta := q
		if mode == "MERGE" {
			delta = -q
		}
		w.T.Supply = w.add(w.T.Supply, delta)
		pairs := w.add(b.Pairs, w.T.Supply)
		if pairs < 0 {
			w.fail("INVALID_SUPPLY")
			return
		}
		w.T.Collateral = w.mul(b.Policy.V, pairs) - b.Collateral
	}
	w.Updates[maker].Order.Remaining -= q
	w.Updates[maker].Order.Filled += q
	w.fee(maker)
	w.Updates[taker].Order.Remaining -= q
	w.Updates[taker].Order.Filled += q
	w.fee(taker)
	w.Fills[w.T.FillCount] = Fill{mode, w.Updates[maker].Order.Id, w.Updates[taker].Order.Id, q, x}
	w.T.FillCount++
	w.T.LastPrice = x
	w.levelChange(b, w.Updates[maker].Order, -q)
}
func (w *Workspace) release(b *Book, at int, share bool, target int64) {
	o := &w.Updates[at].Order
	available, id, a := o.SediOriginal-o.SediConsumed-o.SediReleased, o.SediHoldId, "SEDI"
	if share {
		available = o.SharesOriginal - o.SharesConsumed - o.SharesReleased
		id = o.ShareHoldId
		a = asset(b, *o)
	}
	if target < 0 || target > available {
		w.fail("HOLD_EXCEEDED")
		return
	}
	n := available - target
	if n == 0 {
		return
	}
	w.entry(o.OwnerKind, o.AccountId, a, -n, id)
	w.entry(o.OwnerKind, o.AccountId, a, n, "")
	w.hold("release", *o, a, n, id)
	if share {
		o.SharesReleased += n
	} else {
		o.SediReleased += n
	}
}
func (w *Workspace) fresh(b *Book, o Order, seq int64) string {
	if !validUUID(o.Id) || !validUUID(o.AccountId) || !validUUID(o.SediHoldId) {
		return "INVALID_IDENTIFIER"
	}
	if (o.OwnerKind != "user" && o.OwnerKind != "bot") || (o.OwnerGroup != "" && !validUUID(o.OwnerGroup)) {
		return "INVALID_ORDER_FACTS"
	}
	if (o.Outcome != "YES" && o.Outcome != "NO") || (o.Side != "BUY" && o.Side != "SELL") || (o.Tif != "GTC" && o.Tif != "IOC") {
		return "INVALID_ORDER"
	}
	if o.Limit < b.Policy.Min || o.Limit > b.Policy.Max || o.Limit%b.Policy.Tick != 0 {
		return "INVALID_PRICE"
	}
	if o.Qty < 1 || o.Qty > b.Policy.MaxQty {
		return "INVALID_QUANTITY"
	}
	notional := w.mul(o.Limit, o.Qty)
	if w.Err != "" {
		return w.Err
	}
	if notional < b.Policy.MinNotional {
		return "INVALID_QUANTITY"
	}
	if o.AcceptedSeq != seq || o.Remaining != o.Qty || o.FeePaid || o.Filled != 0 || o.Cancelled != 0 || o.SediConsumed != 0 || o.SediReleased != 0 || o.SharesConsumed != 0 || o.SharesReleased != 0 {
		return "INVALID_ORDER_FACTS"
	}
	expected := int64(1)
	if o.Side == "BUY" {
		expected = w.add(notional, 1)
	}
	if w.Err != "" {
		return w.Err
	}
	if o.SediOriginal != expected || (o.Side == "BUY" && o.SharesOriginal != 0) || (o.Side == "SELL" && o.SharesOriginal != o.Qty) {
		return "INVALID_HOLD_FACTS"
	}
	if o.Side == "SELL" {
		reserved := b.ReservedYes
		if o.Outcome == "NO" {
			reserved = b.ReservedNo
		}
		if !validUUID(o.ShareHoldId) || o.Qty > b.Pairs-reserved {
			return "INVALID_SUPPLY"
		}
	}
	if b.find(o.Id) >= 0 {
		return "DUPLICATE_ORDER"
	}
	return ""
}
func (w *Workspace) match(b *Book, o Order) {
	remaining := o.Remaining
	bid := isBid(o)
	limit := price(b.Policy, o)
	p, step := b.BestAsk, 1
	if !bid {
		p, step = b.BestBid, -1
	}
	for remaining > 0 && p > 0 && p < int(b.Policy.V) {
		if (bid && int64(p) > limit) || (!bid && int64(p) < limit) {
			break
		}
		for slot := b.level(!bid, int64(p)).Head; slot >= 0 && remaining > 0; slot = b.Slots[slot].Next {
			maker := b.Slots[slot].Order
			if maker.AccountId == o.AccountId || (maker.OwnerGroup != "" && maker.OwnerGroup == o.OwnerGroup) {
				w.cancel(b, w.touch(b, -1, o), "SELF_TRADE_PREVENTED")
				return
			}
			if int64(p) < b.Policy.Min || int64(p) > b.Policy.Max || int64(p)%b.Policy.Tick != 0 || price(b.Policy, maker) != int64(p) {
				w.fail("INTERNAL_PRICE_OUT_OF_BAND")
				return
			}
			m := w.touch(b, slot, Order{})
			t := w.touch(b, -1, o)
			if m < 0 || t < 0 {
				return
			}
			q := remaining
			if maker.Remaining < q {
				q = maker.Remaining
			}
			w.fill(b, m, t, int64(p), q)
			if w.Err != "" {
				return
			}
			remaining = w.Updates[t].Order.Remaining
		}
		p += step
	}
	at := w.touch(b, -1, o)
	if at < 0 {
		return
	}
	if remaining > 0 && o.Tif == "IOC" {
		w.cancel(b, at, "IOC_REMAINDER")
	}
	rest := w.Updates[at].Order
	if rest.Remaining > 0 {
		w.levelChange(b, rest, rest.Remaining)
	}
}
func Plan(b *Book, c Command, w *Workspace) string {
	w.Ready = false
	w.Err = ""
	w.T = Transition{BaseSeq: b.Seq, Seq: c.Seq, Ref: c.Ref, Kind: c.Kind, Decision: "ACCEPTED", Mode: b.Mode, Incoming: -1, RestSlot: -1, ReservedYes: b.ReservedYes, ReservedNo: b.ReservedNo}
	w.Prev = b.Hash
	w.Keys.reset()
	w.Bytes.reset()
	if w.Epoch == math.MaxInt64 {
		clear(w.SlotEpoch)
		clear(w.LevelEpoch)
		w.Epoch = 0
	}
	w.Epoch++
	if b.Seq == math.MaxInt64 || c.Seq != b.Seq+1 {
		return "INVALID_SEQUENCE"
	}
	if !validUUID(c.Ref) {
		return "INVALID_COMMAND_REF"
	}
	switch c.Kind {
	case "Place", "RejectPlace", "Cancel", "CancelAll", "Close", "Suspend", "Resume", "Snapshot":
	default:
		return "INVALID_COMMAND"
	}
	if c.Kind == "Place" || c.Kind == "RejectPlace" {
		if e := w.fresh(b, c.Order, c.Seq); e != "" {
			return e
		}
	}
	if c.Kind == "RejectPlace" {
		if !rejectionReason(c.Reason) {
			return "INVALID_REJECTION_REASON"
		}
		w.T.Decision = c.Reason
		w.cancel(b, w.touch(b, -1, c.Order), c.Reason)
	} else if b.Mode == "CLOSED" && c.Kind != "Snapshot" {
		w.T.Decision = "MARKET_CLOSED"
		if c.Kind == "Place" {
			w.cancel(b, w.touch(b, -1, c.Order), "MARKET_CLOSED")
		}
	} else {
		switch c.Kind {
		case "Place":
			if b.Mode == "SUSPENDED" {
				w.T.Decision = "MARKET_SUSPENDED"
				w.cancel(b, w.touch(b, -1, c.Order), "MARKET_SUSPENDED")
			} else {
				w.match(b, c.Order)
			}
		case "Cancel":
			slot := b.find(c.OrderID)
			if slot < 0 {
				w.T.Decision = "ORDER_NOT_OPEN"
			} else if !c.System && b.Slots[slot].Order.AccountId != c.AccountID {
				w.T.Decision = "FORBIDDEN"
			} else {
				w.cancel(b, w.touch(b, slot, Order{}), c.Reason)
			}
		case "CancelAll", "Close":
			reason := c.Reason
			if c.Kind == "Close" {
				reason = "MARKET_CLOSED"
			}
			for s := 0; s < 2; s++ {
				for p := b.Policy.Min; p <= b.Policy.Max; p++ {
					for slot := b.level(s == 0, p).Head; slot >= 0; slot = b.Slots[slot].Next {
						if c.Kind == "Close" || b.Slots[slot].Order.AccountId == c.AccountID {
							w.cancel(b, w.touch(b, slot, Order{}), reason)
							if w.Err != "" {
								break
							}
						}
					}
				}
			}
			if c.Kind == "Close" {
				w.T.Mode = "CLOSED"
			}
		case "Suspend":
			if b.Mode == "OPEN" {
				w.T.Mode = "SUSPENDED"
			} else {
				w.T.Decision = "INVALID_TRANSITION"
			}
		case "Resume":
			if b.Mode == "SUSPENDED" {
				w.T.Mode = "OPEN"
			} else {
				w.T.Decision = "INVALID_TRANSITION"
			}
		}
	}
	if w.Err != "" {
		e := w.Err
		w.T = Transition{}
		return e
	}
	for i := 0; i < w.T.UpdateCount; i++ {
		u := w.Updates[i]
		if u.Fee {
			o := u.Order
			p := w.begin("FEE", "order", o.Id)
			w.Keys.raw("fee:")
			w.Keys.raw(o.Id)
			w.entry(o.OwnerKind, o.AccountId, "SEDI", -1, o.SediHoldId)
			w.hold("consume", o, "SEDI", 1, o.SediHoldId)
			w.entry("system", "system:fees", "SEDI", 1, "")
			w.end(p)
		}
	}
	terminal := -1
	for i := 0; i < w.T.UpdateCount; i++ {
		u := &w.Updates[i]
		o := u.Order
		target := int64(0)
		if o.Side == "BUY" {
			target = w.mul(o.Remaining, o.Limit)
		}
		if o.Remaining > 0 && !o.FeePaid {
			target++
		}
		p := w.begin("ORDER_RELEASE", "order", o.Id)
		w.Keys.raw("release:")
		w.Keys.raw(o.Id)
		w.Keys.raw(":")
		w.Keys.decimal(c.Seq)
		w.release(b, i, false, target)
		if o.Side == "SELL" {
			w.release(b, i, true, o.Remaining)
		}
		if w.T.EntryCount > p.EntryStart {
			w.end(p)
		} else {
			w.Keys.Pos = p.KeyStart
		}
		u.Status = "OPEN"
		if o.Remaining > 0 && o.Filled > 0 {
			u.Status = "PARTIAL"
		}
		if o.Remaining == 0 {
			u.Status = "FILLED"
			if o.Cancelled > 0 {
				u.Status = "CANCELLED"
			}
		}
		before := int64(0)
		if u.Slot >= 0 {
			before = b.Slots[u.Slot].Order.Remaining
			if o.Remaining == 0 {
				terminal = u.Slot
			}
		}
		if o.Side == "SELL" {
			if o.Outcome == "YES" {
				w.T.ReservedYes = w.add(w.T.ReservedYes-before, o.Remaining)
			} else {
				w.T.ReservedNo = w.add(w.T.ReservedNo-before, o.Remaining)
			}
		}
	}
	if w.T.ReservedYes > b.Pairs+w.T.Supply || w.T.ReservedNo > b.Pairs+w.T.Supply {
		w.fail("INVALID_SUPPLY")
	}
	if w.T.Incoming >= 0 && w.Updates[w.T.Incoming].Order.Remaining > 0 {
		slot := terminal
		if b.FreeCount > 0 {
			slot = b.Free[b.FreeCount-1]
		}
		if slot < 0 {
			w.fail("NEED_CAPACITY")
		} else if b.Slots[slot].Generation == math.MaxInt64 {
			w.fail("GENERATION_EXHAUSTED")
		} else {
			w.T.RestSlot = slot
		}
	}
	for s := 0; s < 2; s++ {
		for p := b.Policy.Min; p <= b.Policy.Max; p++ {
			at := s*int(b.Policy.V+1) + int(p)
			if w.LevelEpoch[at] != w.Epoch || w.Totals[at] == b.level(s == 0, p).Total {
				continue
			}
			name := "bid"
			if s == 1 {
				name = "ask"
			}
			w.Deltas[w.T.DeltaCount] = Delta{name, p, w.Totals[at]}
			w.T.DeltaCount++
		}
	}
	if w.Err != "" {
		e := w.Err
		w.T = Transition{}
		return e
	}
	w.encode(b)
	if w.Bytes.Failed {
		return "NEED_CAPACITY"
	}
	w.Next = sha256.Sum256(w.Bytes.Data[:w.Bytes.Pos])
	w.Ready = true
	return ""
}
func (w *Workspace) encode(b *Book) {
	v := &w.Bytes
	v.reset()
	v.span(w.Prev[:])
	v.text("say.transition.v1")
	v.text(b.Policy.MarketID)
	v.text(b.Policy.SeasonID)
	t := w.T
	v.number(t.BaseSeq)
	v.number(t.Seq)
	v.text(t.Ref)
	v.text(t.Kind)
	v.text(t.Decision)
	v.text(t.Mode)
	v.number(int64(t.FillCount))
	for i := 0; i < t.FillCount; i++ {
		f := w.Fills[i]
		v.number(int64(i))
		v.text(f.Mode)
		v.text(f.Maker)
		v.text(f.Taker)
		v.number(f.Qty)
		v.number(f.Price)
	}
	v.number(int64(t.UpdateCount))
	for i := 0; i < t.UpdateCount; i++ {
		u := w.Updates[i]
		writeOrder(v, u.Order)
		v.text(u.Status)
		v.boolean(u.Fee)
		v.text(u.Reason)
	}
	v.boolean(t.RestSlot >= 0)
	if t.RestSlot >= 0 {
		writeOrder(v, w.Updates[t.Incoming].Order)
	}
	v.number(int64(t.PostingCount))
	for i := 0; i < t.PostingCount; i++ {
		p := w.Postings[i]
		v.decimal(int64(p.KeySize))
		v.raw(":")
		v.span(w.Keys.Data[p.KeyStart : p.KeyStart+p.KeySize])
		v.text(p.Kind)
		v.text(b.Policy.SeasonID)
		v.text(b.Policy.MarketID)
		v.text(p.RefType)
		v.text(p.RefID)
		v.number(int64(p.EntryCount))
		for j := p.EntryStart; j < p.EntryStart+p.EntryCount; j++ {
			e := w.Entries[j]
			v.text(e.Kind)
			v.text(e.Owner)
			v.text(e.Asset)
			v.text(e.Bucket)
			v.number(e.Delta)
			v.text(e.Hold)
		}
		v.number(int64(p.HoldCount))
		for j := p.HoldStart; j < p.HoldStart+p.HoldCount; j++ {
			h := w.Holds[j]
			v.text(h.Op)
			v.text(h.ID)
			v.text(h.Kind)
			v.text(h.Owner)
			v.text(h.Asset)
			v.number(h.Amount)
		}
	}
	v.number(t.Supply)
	v.number(t.Supply)
	v.number(t.Collateral)
	v.number(int64(t.DeltaCount))
	for i := 0; i < t.DeltaCount; i++ {
		d := w.Deltas[i]
		v.text(d.Side)
		v.number(d.Price)
		v.number(d.Total)
	}
	v.number(int64(t.FillCount))
	for i := 0; i < t.FillCount; i++ {
		f := w.Fills[i]
		v.number(int64(i))
		v.number(f.Price)
		v.number(f.Qty)
		v.text(side(w.Updates[t.Incoming].Order))
	}
	v.boolean(t.LastPrice != 0)
	if t.LastPrice != 0 {
		v.number(t.LastPrice)
	}
}
func FullHash(b *Book, projected bool, w *Workspace) [32]byte {
	v := &w.Bytes
	v.reset()
	v.text("say.book.v1")
	writePolicy(v, b.Policy)
	mode, seq, hash, pairs, collateral, last, count := b.Mode, b.Seq, b.Hash, b.Pairs, b.Collateral, b.LastPrice, b.Active
	if projected {
		mode = w.T.Mode
		seq = w.T.Seq
		hash = w.Next
		pairs += w.T.Supply
		collateral += w.T.Collateral
		if w.T.LastPrice != 0 {
			last = w.T.LastPrice
		}
		for i := 0; i < w.T.UpdateCount; i++ {
			u := w.Updates[i]
			if u.Slot >= 0 && u.Order.Remaining == 0 {
				count--
			}
			if u.Slot < 0 && u.Order.Remaining > 0 {
				count++
			}
		}
	}
	v.text(mode)
	v.number(seq)
	v.raw("64:")
	v.hash(hash)
	v.number(pairs)
	v.number(collateral)
	v.boolean(last != 0)
	if last != 0 {
		v.number(last)
	}
	v.number(int64(count))
	for s := 0; s < 2; s++ {
		for p := b.Policy.Min; p <= b.Policy.Max; p++ {
			for slot := b.level(s == 0, p).Head; slot >= 0; slot = b.Slots[slot].Next {
				o := b.Slots[slot].Order
				if projected && w.SlotEpoch[slot] == w.Epoch {
					o = w.Updates[w.SlotUpdate[slot]].Order
				}
				if o.Remaining > 0 {
					writeOrder(v, o)
				}
			}
			if projected && w.T.RestSlot >= 0 {
				o := w.Updates[w.T.Incoming].Order
				if isBid(o) == (s == 0) && price(b.Policy, o) == p {
					writeOrder(v, o)
				}
			}
		}
	}
	return sha256.Sum256(v.Data[:v.Pos])
}

func rejectionReason(reason string) bool {
	switch reason {
	case "MARKET_NOT_OPEN", "MARKET_SUSPENDED", "MARKET_CLOSED", "TRADING_HALTED", "SEASON_NOT_ACTIVE", "MARKET_DEGRADED", "ACCOUNT_DISABLED":
		return true
	}
	return false
}
