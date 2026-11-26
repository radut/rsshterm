package screen

import "testing"

func TestParsePPID(t *testing.T) {
	if v, ok := parsePPID("42 (a b) c) S 7 42 42 34816 42"); !ok || v != 7 {
		t.Fatal(v, ok)
	}
	if _, ok := parsePPID("garbage"); ok {
		t.Fatal("garbage parsed")
	}
}
