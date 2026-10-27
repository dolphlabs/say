package main

import (
	"encoding/hex"
	"testing"
)

func TestTransferKeepsFeeAndReleasesImprovement(t *testing.T) {
	b, e := NewBook(fixturePolicy(), 8, 1)
	if e != nil {
		t.Fatal(e)
	}
	w := NewWorkspace(b, 8)
	execute(b, command(1, 1, 11, "YES", "SELL", 60, 1), w)
	c := command(2, 2, 12, "YES", "BUY", 75, 1)
	before := b.Hash
	if e := Plan(b, c, w); e != "" {
		t.Fatal(e)
	}
	if b.Hash != before || b.Seq != 1 {
		t.Fatal("planning changed book")
	}
	if w.T.FillCount != 1 || w.Fills[0].Mode != "TRANSFER_YES" || w.Fills[0].Price != 60 {
		t.Fatal("wrong fill")
	}
	p := w.Postings[w.T.PostingCount-1]
	if p.Kind != "ORDER_RELEASE" || w.Holds[p.HoldStart].Amount != 15 {
		t.Fatal("wrong release")
	}
	projected := FullHash(b, true, w)
	if e := Apply(b, w); e != "" {
		t.Fatal(e)
	}
	if FullHash(b, false, w) != projected {
		t.Fatal("projected hash differs")
	}
	if e := Verify(b, w); e != "" {
		t.Fatal(e)
	}
}
func TestPreallocatedRestingAndCancellationDoNotAllocate(t *testing.T) {
	got := runScenario("rest", 1)
	if got.Allocs != 0 {
		t.Fatalf("hot path allocated %d times", got.Allocs)
	}
	if _, e := hex.DecodeString(got.Hash); e != nil {
		t.Fatal(e)
	}
}
func TestRejectTamperedPlanWithoutApplying(t *testing.T) {
	b, e := NewBook(fixturePolicy(), 8, 0)
	if e != nil {
		t.Fatal(e)
	}
	w := NewWorkspace(b, 8)
	c := command(1, 1, 11, "YES", "BUY", 40, 2)
	if e := Plan(b, c, w); e != "" {
		t.Fatal(e)
	}
	w.Next[0] ^= 1
	if e := Apply(b, w); e != "TRANSITION_HASH_MISMATCH" {
		t.Fatal(e)
	}
	if b.Seq != 0 || b.Active != 0 {
		t.Fatal("applied corrupt transition")
	}
}

func TestAuthoritativeRejectKeepsOpenBookAndReleasesAdmission(t *testing.T) {
	b, e := NewBook(fixturePolicy(), 4, 0)
	if e != nil {
		t.Fatal(e)
	}
	w := NewWorkspace(b, 4)
	execute(b, command(1, 1, 11, "NO", "BUY", 40, 2), w)
	c := command(2, 2, 12, "YES", "BUY", 70, 2)
	c.Kind = "RejectPlace"
	c.Reason = "TRADING_HALTED"
	if e := Plan(b, c, w); e != "" {
		t.Fatal(e)
	}
	if w.T.FillCount != 0 || w.T.Decision != "TRADING_HALTED" || w.T.PostingCount != 1 || w.Holds[0].Amount != 141 {
		t.Fatal("invalid rejection cleanup")
	}
	if e := Apply(b, w); e != "" {
		t.Fatal(e)
	}
	if b.Mode != "OPEN" || b.Active != 1 || b.Pairs != 0 {
		t.Fatal("rejection changed makers or market mode")
	}
}
