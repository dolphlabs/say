package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"runtime"
	"sync"
	"time"
)

func concurrent(cycles int) {
	type done struct {
		commands int
		market   int
		hash     [32]byte
	}
	ready := make(chan int, 1000)
	gate := make(chan struct{})
	finished := make(chan done, 1000)
	var wg sync.WaitGroup
	for number := 0; number < 1000; number++ {
		wg.Add(1)
		go func(number int) {
			defer wg.Done()
			p := fixturePolicy()
			p.MarketID = id(900 + number)
			b, e := NewBook(p, 16, 1000000)
			if e != nil {
				panic(e)
			}
			w := NewWorkspace(b, 16)
			commands := make([]Command, 0, (cycles+20)*2)
			for i := 0; i < cycles+20; i++ {
				c := command(int64(i*2+1), 1000000+number*10000+i, 11, "YES", "BUY", 50, 2)
				commands = append(commands, c)
				c.Kind = "Cancel"
				c.Seq++
				c.OrderID = c.Order.Id
				c.AccountID = c.Order.AccountId
				commands = append(commands, c)
			}
			for _, c := range commands[:40] {
				execute(b, c, w)
			}
			ready <- number
			<-gate
			for _, c := range commands[40:] {
				execute(b, c, w)
			}
			h := b.Hash
			finished <- done{cycles * 2, number, h}
		}(number)
	}
	for i := 0; i < 1000; i++ {
		<-ready
	}
	histories := make([]byte, 32000)
	var before, after runtime.MemStats
	runtime.ReadMemStats(&before)
	began := time.Now()
	close(gate)
	total := 0
	var checksum uint64
	for i := 0; i < 1000; i++ {
		d := <-finished
		total += d.commands
		checksum += uint64(uint32(d.hash[0])<<24 | uint32(d.hash[1])<<16 | uint32(d.hash[2])<<8 | uint32(d.hash[3]))
		copy(histories[d.market*32:], d.hash[:])
	}
	elapsed := time.Since(began).Nanoseconds()
	runtime.ReadMemStats(&after)
	wg.Wait()
	historyHash := sha256.Sum256(histories)
	if e := json.NewEncoder(os.Stdout).Encode(map[string]interface{}{"markets": 1000, "cycles_per_market": cycles, "commands": total, "elapsed_ns": elapsed, "commands_per_second": float64(total) * 1e9 / float64(elapsed), "gc_allocations_including_harness": after.Mallocs - before.Mallocs, "gc_bytes_including_harness": after.TotalAlloc - before.TotalAlloc, "checksum": checksum, "history_digest": hex.EncodeToString(historyHash[:])}); e != nil {
		panic(fmt.Sprint(e))
	}
}
