// Standalone usage collector. Polls the CLIProxyAPI management endpoint
// /usage-queue, splits records by account, and appends to per-account CSVs.
//
// This binary is intentionally independent from the main server so that any
// crash here does not affect the proxy. Configuration is via environment
// variables only — see README or the parent project's deployment docs.
package main

import (
	"context"
	"encoding/csv"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

type record struct {
	Timestamp       string `json:"timestamp"`
	LatencyMs       int64  `json:"latency_ms"`
	Source          string `json:"source"`
	AuthIndex       string `json:"auth_index"`
	Failed          bool   `json:"failed"`
	Provider        string `json:"provider"`
	Model           string `json:"model"`
	Alias           string `json:"alias"`
	Endpoint        string `json:"endpoint"`
	AuthType        string `json:"auth_type"`
	RequestID       string `json:"request_id"`
	Tokens          tokens `json:"tokens"`
}

type tokens struct {
	InputTokens     int64 `json:"input_tokens"`
	OutputTokens    int64 `json:"output_tokens"`
	ReasoningTokens int64 `json:"reasoning_tokens"`
	CachedTokens    int64 `json:"cached_tokens"`
	TotalTokens     int64 `json:"total_tokens"`
}

var csvHeader = []string{
	"timestamp", "provider", "model", "alias", "source",
	"auth_index", "auth_type", "result", "endpoint", "request_id",
	"latency_ms",
	"input_tokens", "output_tokens", "reasoning_tokens", "cached_tokens", "total_tokens",
}

type config struct {
	target    string
	secret    string
	outputDir string
	interval  time.Duration
	batch     int
	bootDelay time.Duration
}

func loadConfig() (config, error) {
	c := config{
		target:    envOr("COLLECTOR_TARGET", "http://127.0.0.1:8080"),
		secret:    strings.TrimSpace(os.Getenv("COLLECTOR_SECRET")),
		outputDir: envOr("COLLECTOR_OUTPUT_DIR", "/data/usage"),
		interval:  envDuration("COLLECTOR_INTERVAL", 10*time.Second, time.Second),
		batch:     envInt("COLLECTOR_BATCH", 500, 1),
		bootDelay: envDuration("COLLECTOR_BOOT_DELAY", 5*time.Second, 0),
	}
	if c.secret == "" {
		return c, fmt.Errorf("COLLECTOR_SECRET is required")
	}
	c.target = strings.TrimRight(c.target, "/")
	return c, nil
}

func envOr(key, def string) string {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		return v
	}
	return def
}

func envInt(key string, def, min int) int {
	raw := strings.TrimSpace(os.Getenv(key))
	if raw == "" {
		return def
	}
	n, err := strconv.Atoi(raw)
	if err != nil || n < min {
		log.Printf("invalid %s=%q, using default %d", key, raw, def)
		return def
	}
	return n
}

func envDuration(key string, def, min time.Duration) time.Duration {
	raw := strings.TrimSpace(os.Getenv(key))
	if raw == "" {
		return def
	}
	d, err := time.ParseDuration(raw)
	if err != nil || d < min {
		log.Printf("invalid %s=%q, using default %s", key, raw, def)
		return def
	}
	return d
}

func main() {
	log.SetFlags(log.LstdFlags | log.Lmicroseconds)
	log.SetPrefix("[usage-collector] ")

	cfg, err := loadConfig()
	if err != nil {
		log.Fatalf("config error: %v", err)
	}

	if err := os.MkdirAll(cfg.outputDir, 0o755); err != nil {
		log.Fatalf("mkdir output dir: %v", err)
	}

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	log.Printf("starting target=%s output=%s interval=%s batch=%d",
		cfg.target, cfg.outputDir, cfg.interval, cfg.batch)

	if cfg.bootDelay > 0 {
		select {
		case <-time.After(cfg.bootDelay):
		case <-ctx.Done():
			return
		}
	}

	client := &http.Client{Timeout: 15 * time.Second}
	w := &csvWriter{dir: cfg.outputDir}

	for {
		runOnce(ctx, client, cfg, w)
		select {
		case <-time.After(cfg.interval):
		case <-ctx.Done():
			log.Printf("shutdown signal received, exiting")
			return
		}
	}
}

func runOnce(ctx context.Context, client *http.Client, cfg config, w *csvWriter) {
	defer func() {
		if r := recover(); r != nil {
			log.Printf("panic recovered in poll loop: %v", r)
		}
	}()

	items, err := fetch(ctx, client, cfg)
	if err != nil {
		log.Printf("fetch failed: %v", err)
		return
	}
	if len(items) == 0 {
		return
	}

	buckets := make(map[string][]record, 8)
	for _, raw := range items {
		var rec record
		if err := json.Unmarshal(raw, &rec); err != nil {
			log.Printf("unmarshal record skipped: %v (%s)", err, truncate(string(raw), 200))
			continue
		}
		name := fileNameFor(rec)
		buckets[name] = append(buckets[name], rec)
	}

	for name, recs := range buckets {
		if err := w.append(name, recs); err != nil {
			log.Printf("write %s failed: %v", name, err)
		}
	}
	log.Printf("flushed %d records into %d files", len(items), len(buckets))
}

func fetch(ctx context.Context, client *http.Client, cfg config) ([]json.RawMessage, error) {
	url := fmt.Sprintf("%s/v0/management/usage-queue?count=%d", cfg.target, cfg.batch)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("X-Management-Key", cfg.secret)
	req.Header.Set("Accept", "application/json")

	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return nil, fmt.Errorf("status %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}

	var items []json.RawMessage
	if err := json.NewDecoder(resp.Body).Decode(&items); err != nil {
		return nil, fmt.Errorf("decode: %w", err)
	}
	return items, nil
}

func fileNameFor(r record) string {
	provider := sanitizeSegment(r.Provider, "unknown")
	if r.Source != "" {
		return fmt.Sprintf("%s_%s.csv", provider, sanitizeSegment(r.Source, "src"))
	}
	if r.AuthIndex != "" {
		return fmt.Sprintf("%s_%s_%s.csv",
			provider,
			sanitizeSegment(r.AuthType, "auth"),
			sanitizeSegment(r.AuthIndex, "idx"),
		)
	}
	return "_unknown.csv"
}

func sanitizeSegment(s, fallback string) string {
	s = strings.TrimSpace(s)
	if s == "" {
		return fallback
	}
	const unsafe = `/\:*?"<>|` + "\r\n\t"
	var b strings.Builder
	b.Grow(len(s))
	for _, r := range s {
		if strings.ContainsRune(unsafe, r) {
			b.WriteByte('_')
		} else {
			b.WriteRune(r)
		}
	}
	out := b.String()
	if len(out) > 100 {
		out = out[:100]
	}
	out = strings.Trim(out, "._ ")
	if out == "" {
		return fallback
	}
	return out
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "..."
}

type csvWriter struct {
	mu  sync.Mutex
	dir string
}

func (w *csvWriter) append(name string, recs []record) error {
	w.mu.Lock()
	defer w.mu.Unlock()

	path := filepath.Join(w.dir, name)
	_, statErr := os.Stat(path)
	needHeader := os.IsNotExist(statErr)

	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()

	cw := csv.NewWriter(f)
	if needHeader {
		if err := cw.Write(csvHeader); err != nil {
			return err
		}
	}
	for _, r := range recs {
		row := []string{
			r.Timestamp,
			r.Provider,
			r.Model,
			r.Alias,
			r.Source,
			r.AuthIndex,
			r.AuthType,
			resultStr(r.Failed),
			r.Endpoint,
			r.RequestID,
			strconv.FormatInt(r.LatencyMs, 10),
			strconv.FormatInt(r.Tokens.InputTokens, 10),
			strconv.FormatInt(r.Tokens.OutputTokens, 10),
			strconv.FormatInt(r.Tokens.ReasoningTokens, 10),
			strconv.FormatInt(r.Tokens.CachedTokens, 10),
			strconv.FormatInt(r.Tokens.TotalTokens, 10),
		}
		if err := cw.Write(row); err != nil {
			return err
		}
	}
	cw.Flush()
	return cw.Error()
}

func resultStr(failed bool) string {
	if failed {
		return "failed"
	}
	return "success"
}
