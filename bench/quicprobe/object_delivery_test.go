package main

import (
	"encoding/binary"
	"testing"
	"time"
)

// object builds one object of objectSize bytes whose first 8 bytes are the
// big-endian send timestamp in nanoseconds.
func object(sendNS int64, objectSize int) []byte {
	b := make([]byte, objectSize)
	binary.BigEndian.PutUint64(b[:8], uint64(sendNS))
	return b
}

func TestObjectChunkerRecordsDelayPerObject(t *testing.T) {
	const objectSize = 16
	nowNS := int64(2 * time.Millisecond) // 2,000,000 ns

	stream := append(object(0, objectSize), object(int64(time.Millisecond), objectSize)...)

	var delays []int64
	chunker := &objectChunker{objectSize: objectSize}
	// Feed in awkward splits, including one that lands inside the second
	// object's header, to prove the header survives across reads.
	for _, cut := range [][]byte{stream[:5], stream[5:20], stream[20:]} {
		delays = append(delays, chunker.feed(cut, nowNS)...)
	}

	if len(delays) != 2 {
		t.Fatalf("got %d delays, want 2", len(delays))
	}
	// object 1: send 0 => delay = now; object 2: send 1ms => delay = now - 1ms.
	if delays[0] != nowNS {
		t.Errorf("delays[0] = %d, want %d", delays[0], nowNS)
	}
	if delays[1] != nowNS-int64(time.Millisecond) {
		t.Errorf("delays[1] = %d, want %d", delays[1], nowNS-int64(time.Millisecond))
	}
}

func TestObjectChunkerIgnoresTrailingPartialObject(t *testing.T) {
	const objectSize = 16
	stream := append(object(0, objectSize), make([]byte, 7)...) // one whole + partial

	chunker := &objectChunker{objectSize: objectSize}
	delays := chunker.feed(stream, int64(time.Millisecond))

	if len(delays) != 1 {
		t.Fatalf("delivered %d objects, want 1 (partial trailing object ignored)", len(delays))
	}
}

func TestDeliveryDelayStatsMinAndPercentiles(t *testing.T) {
	d := newDeliveryDelayStats()
	for i := 1; i <= 100; i++ {
		d.record(int64(i) * int64(time.Millisecond)) // 1..100 ms
	}

	if d.count != 100 {
		t.Fatalf("count = %d, want 100", d.count)
	}
	if d.minMS != 1 {
		t.Errorf("minMS = %d, want 1", d.minMS)
	}
	summary := d.summary()
	if summary.count != 100 {
		t.Fatalf("count = %d, want 100", summary.count)
	}
	if summary.minMS != 1 {
		t.Errorf("minMS = %d, want 1", summary.minMS)
	}
	if summary.p50MS < 45 || summary.p50MS > 55 {
		t.Errorf("p50 = %d ms, want ~50", summary.p50MS)
	}
	if summary.p99MS < 95 || summary.p99MS > 100 {
		t.Errorf("p99 = %d ms, want ~99", summary.p99MS)
	}
}

func TestDeliveryDelayStatsEmpty(t *testing.T) {
	d := newDeliveryDelayStats()
	summary := d.summary()
	if summary.p50MS != 0 {
		t.Errorf("empty p50 = %d, want 0", summary.p50MS)
	}
	if summary.minMS != 0 {
		t.Errorf("empty min = %d, want 0", summary.minMS)
	}
}
