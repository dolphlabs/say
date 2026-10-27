package main

import (
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"runtime"
	"sort"
	"strconv"
	"time"
	"unsafe"
)

func id(n int) string       { return fmt.Sprintf("00000000-0000-4000-a000-%012d", n) }
func fixturePolicy() Policy { return Policy{id(900), id(901), 100, 1, 99, 1, 100000, 2} }
func command(seq int64, number, account int, outcome, side string, p, q int64) Command {
	o := Order{Id: id(number), AccountId: id(account), OwnerKind: "user", Outcome: outcome, Side: side, Limit: p, Qty: q, Remaining: q, Tif: "GTC", AcceptedSeq: seq, SediHoldId: id(100000000 + number*2), SediOriginal: 1}
	if side == "BUY" {
		o.SediOriginal = p*q + 1
	} else {
		o.ShareHoldId = id(100000001 + number*2)
		o.SharesOriginal = q
	}
	return Command{Kind: "Place", Seq: seq, Ref: o.Id, Order: o, Reason: "USER_CANCEL"}
}
func execute(b *Book, c Command, w *Workspace) {
	if e := Plan(b, c, w); e != "" {
		panic(e)
	}
	if e := Apply(b, w); e != "" {
		panic(e)
	}
}

type Report struct {
	Scenario             string  `json:"scenario"`
	Samples              []int64 `json:"samples_ns"`
	Commands             int     `json:"commands"`
	P50                  int64   `json:"p50_ns"`
	P99                  int64   `json:"p99_ns"`
	P999                 int64   `json:"p999_ns"`
	Rate                 float64 `json:"commands_per_second"`
	Allocs               uint64  `json:"gc_allocations"`
	Bytes                uint64  `json:"gc_bytes"`
	BookBufferBytes      int64   `json:"book_buffer_bytes"`
	WorkspaceBufferBytes int64   `json:"workspace_buffer_bytes"`
	OrderBytes           uintptr `json:"order_record_bytes"`
	SlotBytes            uintptr `json:"slot_record_bytes"`
	BucketBytes          uintptr `json:"index_bucket_bytes"`
	Hash                 string  `json:"final_hash"`
}

func runScenario(name string, count int) Report {
	capacity := 16
	if name == "cancel_storm" {
		capacity = 10001
	}
	b, e := NewBook(fixturePolicy(), capacity, 1000000)
	if e != nil {
		panic(e)
	}
	w := NewWorkspace(b, capacity)
	commands := make([]Command, count+200)
	for i := range commands {
		commands[i] = command(0, 1000000+i, 11, "YES", "BUY", 50, 2)
	}
	samples := make([]int64, count)
	cancelIDs := make([]string, 0, 10000)
	if name == "cancel_storm" {
		for i := 0; i < 10000; i++ {
			c := command(b.Seq+1, 2000000+i, 11, "YES", "BUY", 50, 2)
			cancelIDs = append(cancelIDs, c.Order.Id)
			execute(b, c, w)
		}
	}
	var allocs, bytes uint64
	for iteration := 0; iteration < count+200; iteration++ {
		warmup := iteration < 200
		c := commands[iteration]
		c.Seq = b.Seq + 1
		c.Order.AcceptedSeq = c.Seq
		switch name {
		case "cancel":
			execute(b, c, w)
			c.Kind = "Cancel"
			c.Seq = b.Seq + 1
			c.OrderID = c.Order.Id
			c.AccountID = c.Order.AccountId
		case "fill_one":
			m := c
			m.Order.Side = "SELL"
			m.Order.AccountId = id(12)
			m.Order.SediOriginal = 1
			m.Order.ShareHoldId = id(3000000 + iteration)
			m.Order.SharesOriginal = 2
			execute(b, m, w)
			c = command(b.Seq+1, 4000000+iteration, 11, "YES", "BUY", 60, 2)
		case "walk_transfer_mint", "walk_transfer_merge":
			for level := 0; level < 10; level++ {
				m := command(b.Seq+1, 5000000+iteration*10+level, 12, "YES", "SELL", int64(45+level), 2)
				if name == "walk_transfer_mint" && level%2 == 1 {
					m.Order.Outcome = "NO"
					m.Order.Side = "BUY"
					m.Order.Limit = int64(55 - level)
					m.Order.SediOriginal = m.Order.Limit*2 + 1
					m.Order.ShareHoldId = ""
					m.Order.SharesOriginal = 0
				}
				if name == "walk_transfer_merge" {
					m = command(b.Seq+1, 5000000+iteration*10+level, 12, "YES", "BUY", int64(54-level), 2)
					if level%2 == 1 {
						m.Order.Outcome = "NO"
						m.Order.Side = "SELL"
						m.Order.Limit = int64(46 + level)
						m.Order.SediOriginal = 1
						m.Order.ShareHoldId = id(20000000 + iteration*10 + level)
						m.Order.SharesOriginal = 2
					}
				}
				execute(b, m, w)
			}
			c = command(b.Seq+1, 6000000+iteration, 11, "YES", "BUY", 60, 20)
			if name == "walk_transfer_merge" {
				c = command(b.Seq+1, 6000000+iteration, 11, "YES", "SELL", 40, 20)
			}
		case "cancel_storm":
			if warmup {
				maker := command(b.Seq+1, 7000000+iteration, 11, "NO", "BUY", 20, 2)
				execute(b, maker, w)
				c.Kind = "Cancel"
				c.Seq = b.Seq + 1
				c.OrderID = maker.Order.Id
				c.AccountID = maker.Order.AccountId
			} else {
				c.Kind = "Cancel"
				c.OrderID = cancelIDs[iteration-200]
				c.AccountID = id(11)
			}
		}
		var before, after runtime.MemStats
		runtime.ReadMemStats(&before)
		start := time.Now()
		execute(b, c, w)
		elapsed := time.Since(start).Nanoseconds()
		runtime.ReadMemStats(&after)
		if !warmup {
			samples[iteration-200] = elapsed
			allocs += after.Mallocs - before.Mallocs
			bytes += after.TotalAlloc - before.TotalAlloc
		}
		if name == "rest" {
			c.Kind = "Cancel"
			c.Seq = b.Seq + 1
			c.OrderID = c.Order.Id
			c.AccountID = c.Order.AccountId
			execute(b, c, w)
		}
	}
	if err := Verify(b, w); err != "" {
		panic(err)
	}
	sort.Slice(samples, func(i, j int) bool { return samples[i] < samples[j] })
	var total int64
	for _, n := range samples {
		total += n
	}
	return Report{name, samples, count, samples[count/2], samples[(count-1)*99/100], samples[(count-1)*999/1000], float64(count) * 1e9 / float64(total), allocs, bytes, bookMemory(b), workspaceMemory(w), unsafe.Sizeof(Order{}), unsafe.Sizeof(Slot{}), unsafe.Sizeof(Bucket{}), hex.EncodeToString(b.Hash[:])}
}

type Check struct {
	Command Command `json:"command"`
	State   string  `json:"expected_state_hash"`
	Full    string  `json:"expected_full_hash"`
	Error   string  `json:"expected_error"`
}
type Case struct {
	Policy   Policy  `json:"policy"`
	Pairs    int64   `json:"pairs"`
	Capacity int     `json:"capacity"`
	Commands []Check `json:"commands"`
}
type Manifest struct {
	Files   []string `json:"files"`
	Workers int      `json:"workers"`
}

func verifyManifest(path string) error {
	data, e := os.ReadFile(path)
	if e != nil {
		return e
	}
	var manifest Manifest
	if e = json.Unmarshal(data, &manifest); e != nil {
		return e
	}
	total, cases := 0, 0
	for _, path := range manifest.Files {
		data, e := os.ReadFile(path)
		if e != nil {
			return e
		}
		var bundle struct {
			Cases []Case `json:"cases"`
		}
		if e = json.Unmarshal(data, &bundle); e != nil {
			return e
		}
		for _, c := range bundle.Cases {
			cases++
			b, e := NewBook(c.Policy, c.Capacity, c.Pairs)
			if e != nil {
				return e
			}
			w := NewWorkspace(b, c.Capacity)
			for index, check := range c.Commands {
				got := Plan(b, check.Command, w)
				if check.Error != "" {
					if got != check.Error {
						return fmt.Errorf("%s command %d error %q != %q", path, index, got, check.Error)
					}
					if check.State != "" && hex.EncodeToString(b.Hash[:]) != check.State {
						return fmt.Errorf("%s command %d rejection changed rolling hash", path, index)
					}
					if check.Full != "" {
						full := FullHash(b, false, w)
						if hex.EncodeToString(full[:]) != check.Full {
							return fmt.Errorf("%s command %d rejection changed book", path, index)
						}
					}
					total++
					continue
				}
				if got != "" {
					return fmt.Errorf("%s command %d plan %s", path, index, got)
				}
				if hex.EncodeToString(w.Next[:]) != check.State {
					return fmt.Errorf("%s command %d rolling hash mismatch", path, index)
				}
				full := FullHash(b, true, w)
				if hex.EncodeToString(full[:]) != check.Full {
					return fmt.Errorf("%s command %d full hash mismatch", path, index)
				}
				if got = Apply(b, w); got != "" {
					return fmt.Errorf("%s command %d apply %s", path, index, got)
				}
				if got = Verify(b, w); got != "" {
					return fmt.Errorf("%s command %d invariant %s", path, index, got)
				}
				total++
			}
		}
	}
	return json.NewEncoder(os.Stdout).Encode(map[string]int{"commands": total, "cases": cases})
}
func main() {
	if len(os.Args) == 3 && os.Args[1] == "--concurrent" {
		n, e := strconv.Atoi(os.Args[2])
		if e != nil || n < 1 || n > 1000 {
			panic("invalid cycles")
		}
		concurrent(n)
		return
	}
	if len(os.Args) == 3 && os.Args[1] == "--verify" {
		if e := verifyManifest(os.Args[2]); e != nil {
			fmt.Fprintln(os.Stderr, e)
			os.Exit(1)
		}
		return
	}
	count := 10000
	if len(os.Args) > 1 {
		var e error
		count, e = strconv.Atoi(os.Args[1])
		if e != nil || count < 1 || count > 10000 {
			panic("count must be 1..10000")
		}
	}
	for _, name := range []string{"rest", "cancel", "fill_one", "walk_transfer_mint", "walk_transfer_merge", "cancel_storm"} {
		if e := json.NewEncoder(os.Stdout).Encode(runScenario(name, count)); e != nil {
			panic(e)
		}
	}
}

func bookMemory(b *Book) int64 {
	return int64(unsafe.Sizeof(*b)) + int64(cap(b.Slots))*int64(unsafe.Sizeof(Slot{})) + int64(cap(b.Bids)+cap(b.Asks))*int64(unsafe.Sizeof(Level{})) + int64(cap(b.Index))*int64(unsafe.Sizeof(Bucket{})) + int64(cap(b.Free))*int64(unsafe.Sizeof(int(0)))
}
func workspaceMemory(w *Workspace) int64 {
	return int64(unsafe.Sizeof(*w)) + int64(cap(w.Fills))*int64(unsafe.Sizeof(Fill{})) + int64(cap(w.Updates))*int64(unsafe.Sizeof(Update{})) + int64(cap(w.Postings))*int64(unsafe.Sizeof(Posting{})) + int64(cap(w.Entries))*int64(unsafe.Sizeof(Entry{})) + int64(cap(w.Holds))*int64(unsafe.Sizeof(Hold{})) + int64(cap(w.Deltas))*int64(unsafe.Sizeof(Delta{})) + int64(cap(w.SlotEpoch)+cap(w.LevelEpoch)+cap(w.Totals))*8 + int64(cap(w.Seen)+cap(w.SlotUpdate))*int64(unsafe.Sizeof(int(0))) + int64(cap(w.Keys.Data)+cap(w.Bytes.Data))
}
