package storage

import (
	"reflect"
	"testing"
)

func TestIndexEventsTracksRangeAndKeyframes(t *testing.T) {
	ix := indexEvents([]eventHeader{
		{Type: 3, Timestamp: 120},
		{Type: 4, Timestamp: 100},
		{Type: 2, Timestamp: 101},
		{Type: 5, Timestamp: 150, Subtype: "click"},
	})
	if ix.First != 100 || ix.Last != 150 || ix.Count != 4 {
		t.Fatalf("range = %d..%d count %d", ix.First, ix.Last, ix.Count)
	}
	if !reflect.DeepEqual(ix.Fulls, []int64{101}) || !reflect.DeepEqual(ix.Metas, []int64{100}) {
		t.Fatalf("fulls %v metas %v", ix.Fulls, ix.Metas)
	}
}

func TestThinKeepsEndsAndCap(t *testing.T) {
	var ts []int64
	for i := int64(0); i < 500; i++ {
		ts = append(ts, i*10)
	}
	out := thin(ts, maxIndexedPerList)
	if len(out) != maxIndexedPerList || out[0] != 0 || out[len(out)-1] != 4990 {
		t.Fatalf("len %d first %d last %d", len(out), out[0], out[len(out)-1])
	}
}

func TestMetadataRoundTripFitsS3Limit(t *testing.T) {
	var hs []eventHeader
	for i := int64(0); i < 300; i++ {
		hs = append(hs, eventHeader{Type: 4, Timestamp: 1794800000000 + i}, eventHeader{Type: 2, Timestamp: 1794800000000 + i})
	}
	ix := indexEvents(hs)
	md := ix.toMetadata()
	size := 0
	for k, v := range md {
		size += len("x-amz-meta-") + len(k) + len(v)
	}
	if size > 2048 {
		t.Fatalf("metadata %d bytes exceeds S3's 2 KB", size)
	}
	// Servers return keys with the prefix and in other cases.
	echoed := map[string]string{}
	for k, v := range md {
		echoed["X-Amz-Meta-"+k] = v
	}
	got, ok := indexFromMetadata(echoed)
	if !ok || got.First != ix.First || got.Last != ix.Last || got.Count != ix.Count ||
		!reflect.DeepEqual(got.Fulls, ix.Fulls) || !reflect.DeepEqual(got.Metas, ix.Metas) {
		t.Fatalf("round trip mismatch: %+v vs %+v", got, ix)
	}
	if _, ok := indexFromMetadata(map[string]string{"Content-Type": "x"}); ok {
		t.Fatal("object without index metadata must report !ok")
	}
}

func TestLastMetaAtOrBeforeAndKeyframes(t *testing.T) {
	idx := []BatchIndex{
		{Key: "a", Metas: []int64{100}, Fulls: []int64{101}},
		{Key: "b", Metas: []int64{500}, Fulls: []int64{501, 101}},
	}
	if k, ts, ok := lastMetaAtOrBefore(idx, 499); !ok || k != "a" || ts != 100 {
		t.Fatalf("got %s %d %v", k, ts, ok)
	}
	if k, ts, ok := lastMetaAtOrBefore(idx, 501); !ok || k != "b" || ts != 500 {
		t.Fatalf("got %s %d %v", k, ts, ok)
	}
	if _, _, ok := lastMetaAtOrBefore(idx, 50); ok {
		t.Fatal("no meta before 50")
	}
	if got := Keyframes(idx); !reflect.DeepEqual(got, []int64{101, 501}) {
		t.Fatalf("keyframes %v", got)
	}
}

func TestFilters(t *testing.T) {
	r := InRange(100, 200)
	if !r(eventHeader{Timestamp: 100}) || r(eventHeader{Timestamp: 200}) || r(eventHeader{Timestamp: 99}) {
		t.Fatal("InRange must be [from, to)")
	}
	a := ActivityOnly()
	if !a(eventHeader{Type: 4}) || !a(eventHeader{Type: 5, Subtype: "network"}) ||
		a(eventHeader{Type: 5}) || a(eventHeader{Type: 3}) || a(eventHeader{Type: 2}) {
		t.Fatal("ActivityOnly keeps Meta and tagged custom events only")
	}
}
