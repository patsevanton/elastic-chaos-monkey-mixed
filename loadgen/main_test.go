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
	if bulkErr.Load() != 1 {
		t.Fatalf("bulk_err %d", bulkErr.Load())
	}
	if err := postBulk(srv.URL, doc("id-2", time.Unix(0, 0).UTC(), "")); err != nil {
		t.Fatal(err)
	}
	if bulkOK.Load() != 1 {
		t.Fatalf("bulk_ok %d", bulkOK.Load())
	}
}

func TestAcceptedBulkIsFound(t *testing.T) {
	var stored string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.Contains(r.URL.Path, "_bulk") {
			w.Write([]byte(`{"items":[{"index":{"status":201,"result":"created"}}]}`))
			return
		}
		if strings.Contains(r.URL.Path, "_mget") {
			w.Write([]byte(`{"docs":[{"found":true,"_id":"` + stored + `"}]}`))
			return
		}
		http.NotFound(w, r)
	}))
	defer srv.Close()
	id, err := postBulkID(srv.URL, "id-kept")
	if err != nil {
		t.Fatal(err)
	}
	stored = id
	if !mgetFound(srv.URL, id) {
		t.Fatal("accepted id not found")
	}
}
