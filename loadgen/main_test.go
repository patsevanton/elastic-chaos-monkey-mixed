package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestDocSize(t *testing.T) {
	b := doc("id-1", time.Unix(0, 0).UTC(), "")
	if len(b) != 2048 {
		t.Fatalf("size %d", len(b))
	}
}

func TestBulkCounts(t *testing.T) {
	okBody := `{"items":[{"index":{"status":201}}]}`
	errHits := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.Contains(r.URL.Path, "_bulk") && errHits == 0 {
			errHits++
			http.Error(w, "no", 500)
			return
		}
		w.Write([]byte(okBody))
	}))
	defer srv.Close()

	if err := postBulk(srv.URL, doc("id-1", time.Unix(0, 0).UTC(), "")); err == nil {
		t.Fatal("expected bulk error")
	}
	if err := postBulk(srv.URL, doc("id-2", time.Unix(0, 0).UTC(), "")); err != nil {
		t.Fatal(err)
	}
}
