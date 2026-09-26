package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

const indexName = "load"

var (
	bulkOKC    = prometheus.NewCounter(prometheus.CounterOpts{Name: "loadgen_bulk_ok_total"})
	bulkErrC   = prometheus.NewCounter(prometheus.CounterOpts{Name: "loadgen_bulk_err_total"})
	searchOKC  = prometheus.NewCounter(prometheus.CounterOpts{Name: "loadgen_search_ok_total"})
	searchErrC = prometheus.NewCounter(prometheus.CounterOpts{Name: "loadgen_search_err_total"})
)

func doc(id string, ts time.Time, zone string) []byte {
	prefix, err := json.Marshal(map[string]string{
		"id":   id,
		"ts":   ts.UTC().Format(time.RFC3339),
		"zone": zone,
		"body": "",
	})
	if err != nil {
		panic(err)
	}
	// "body":"" is 8 bytes; pad inside the string to 2048.
	pad := 2048 - len(prefix)
	if pad < 0 {
		panic(fmt.Sprintf("fields exceed 2048: %d", len(prefix)))
	}
	out, err := json.Marshal(map[string]string{
		"id":   id,
		"ts":   ts.UTC().Format(time.RFC3339),
		"zone": zone,
		"body": string(bytes.Repeat([]byte("x"), pad)),
	})
	if err != nil {
		panic(err)
	}
	if len(out) != 2048 {
		panic(fmt.Sprintf("size %d", len(out)))
	}
	return out
}

func postBulk(es string, body []byte) error {
	var meta struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(body, &meta); err != nil {
		bulkErrC.Inc()
		return err
	}
	var buf bytes.Buffer
	fmt.Fprintf(&buf, `{"index":{"_index":"%s","_id":"%s"}}`+"\n", indexName, meta.ID)
	buf.Write(body)
	buf.WriteByte('\n')
	resp, err := http.Post(es+"/"+indexName+"/_bulk", "application/x-ndjson", &buf)
	if err != nil {
		bulkErrC.Inc()
		return err
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	if resp.StatusCode >= 300 {
		bulkErrC.Inc()
		return fmt.Errorf("bulk %d", resp.StatusCode)
	}
	var parsed struct {
		Errors bool `json:"errors"`
		Items  []struct {
			Index struct {
				Status int    `json:"status"`
				Result string `json:"result"`
			} `json:"index"`
		} `json:"items"`
	}
	if err := json.Unmarshal(raw, &parsed); err != nil || parsed.Errors || len(parsed.Items) != 1 || parsed.Items[0].Index.Status >= 300 {
		bulkErrC.Inc()
		return fmt.Errorf("bulk item")
	}
	bulkOKC.Inc()
	fmt.Printf("id %s\n", meta.ID)
	return nil
}

func stringsReader(s string) *bytes.Reader { return bytes.NewReader([]byte(s)) }

func main() {
	es := flag.String("es", os.Getenv("ES_URL"), "elasticsearch url")
	flag.Parse()
	if *es == "" {
		fmt.Fprintln(os.Stderr, "ES_URL")
		os.Exit(1)
	}
	prometheus.MustRegister(bulkOKC, bulkErrC, searchOKC, searchErrC)
	go http.ListenAndServe(":8080", promhttp.Handler())
	ensureIndex(*es)
	go searchLoop(*es)
	bulkLoop(*es)
}

func ensureIndex(es string) {
	body := `{"settings":{"number_of_shards":1,"number_of_replicas":2}}`
	req, _ := http.NewRequest(http.MethodPut, es+"/"+indexName, stringsReader(body))
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	resp.Body.Close()
}

func bulkLoop(es string) {
	for i := 0; ; i++ {
		id := fmt.Sprintf("%d-%d", time.Now().UnixNano(), i)
		// zone пустая: под не знает свою зону, downward API и env ZONE нет.
		// Паддинг body считается от этой пустой строки, размер документа остаётся 2048.
		_ = postBulk(es, doc(id, time.Now(), ""))
	}
}

func searchLoop(es string) {
	for {
		resp, err := http.Post(es+"/"+indexName+"/_search", "application/json", stringsReader(`{"size":1,"query":{"match_all":{}}}`))
		if err != nil || resp.StatusCode >= 300 {
			searchErrC.Inc()
		} else {
			searchOKC.Inc()
		}
		if resp != nil {
			resp.Body.Close()
		}
	}
}
