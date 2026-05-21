# LOCAL_CHANGE.md

本文档记录本 fork 相对 upstream 的本地改动。目标是：即使以后用 upstream 代码覆盖本地仓库，也能根据本文档恢复本 fork 的生产功能。

生成时状态：
- 本地分支：`main`
- 本地 HEAD：`6d663b68 Document CPA Free deployment topology`
- upstream 基线：`785b00c3127eea6aa207f1207ead8a2aa93690a3`
- 当时 upstream/main：`21fad9db Merge pull request #3477 from router-for-me/cluster`
- 本地相对 upstream 的独有改动：`21 files changed, 1290 insertions(+), 33 deletions(-)`

## 一键精确恢复

如果本地提交还在 `origin/main`，这是最可靠的恢复方式：

```bash
git fetch origin main
git checkout 6d663b68 -- \
  .cnb.yml \
  .gitignore \
  AGENTS.md \
  CLAUDE.md \
  Dockerfile \
  Makefile \
  RAILWAY_DEPLOY.md \
  cmd/usage-collector/main.go \
  docker-build.ps1 \
  docker-build.sh \
  docker-compose.uat.yml \
  docker-compose.yml \
  internal/api/handlers/management/handler.go \
  internal/api/handlers/management/handler_test.go \
  internal/api/redis_queue_protocol_integration_test.go \
  railway.toml \
  railway.yaml \
  scripts/backup.sh \
  scripts/deploy.sh \
  scripts/rollback.sh \
  start.sh
chmod +x scripts/backup.sh scripts/deploy.sh scripts/rollback.sh start.sh
gofmt -w cmd/usage-collector/main.go internal/api/handlers/management/handler.go internal/api/handlers/management/handler_test.go internal/api/redis_queue_protocol_integration_test.go
go build -o test-output ./cmd/server && rm -f test-output
go build -o test-output-collector ./cmd/usage-collector && rm -f test-output-collector
```

如果 future upstream 已经大改同名文件，上面命令会把这些文件恢复为本地 fork 的精确版本，可能覆盖 upstream 新增内容。生产优先时可这样做；要长期合并 upstream，则按下方“手工恢复清单”逐项嫁接。

## 文件清单

新增文件：
- `.cnb.yml`
- `CLAUDE.md`
- `Makefile`
- `RAILWAY_DEPLOY.md`
- `cmd/usage-collector/main.go`
- `docker-compose.uat.yml`
- `railway.toml`
- `railway.yaml`
- `scripts/backup.sh`
- `scripts/deploy.sh`
- `scripts/rollback.sh`
- `start.sh`

修改 upstream 文件：
- `.gitignore`
- `AGENTS.md`
- `Dockerfile`
- `docker-build.ps1`
- `docker-build.sh`
- `docker-compose.yml`
- `internal/api/handlers/management/handler.go`
- `internal/api/handlers/management/handler_test.go`
- `internal/api/redis_queue_protocol_integration_test.go`

## 必须恢复的功能

### 1. CNB Docker 自动构建

文件：`.cnb.yml`

作用：
- push 到 `cnb/main` 后自动构建并推送镜像。
- 镜像名由 CNB 环境变量决定，当前生产使用 `docker.cnb.cool/jung.ren/cliproxyapi:latest`。

完整内容：

```yaml
main:
  push:
    - services:
        - docker
      stages:
        - name: Docker build
          script: docker build -t ${CNB_DOCKER_REGISTRY}/${CNB_REPO_SLUG_LOWERCASE}:latest .
        - name: Docker push
          script: docker push ${CNB_DOCKER_REGISTRY}/${CNB_REPO_SLUG_LOWERCASE}:latest
```

### 2. Usage Collector

文件：`cmd/usage-collector/main.go`

作用：
- 作为独立二进制 `cpa-usage-collector` 打进 Docker 镜像。
- 容器启动时由 `start.sh` 后台启动。
- 每隔 `COLLECTOR_INTERVAL` 轮询主服务的 `/v0/management/usage-queue?count=<COLLECTOR_BATCH>`。
- 使用 HTTP header `X-Management-Key: <COLLECTOR_SECRET>` 鉴权。
- 将 usage records 按账号拆分为 CSV，写到 `COLLECTOR_OUTPUT_DIR`，生产默认是 `/data/usage`。
- collector 崩溃不能影响主 proxy，因此由 `start.sh` 后台启动，主进程仍 `exec ./CLIProxyAPI`。

环境变量：
- `COLLECTOR_TARGET`，默认 `http://127.0.0.1:8080`
- `COLLECTOR_SECRET`，必填，生产默认通过 compose 注入
- `COLLECTOR_OUTPUT_DIR`，默认 `/data/usage`
- `COLLECTOR_INTERVAL`，默认 `10s`
- `COLLECTOR_BATCH`，默认 `500`
- `COLLECTOR_BOOT_DELAY`，默认 `5s`

完整内容：

```go
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
```

### 3. Dockerfile

文件：`Dockerfile`

必须保留：
- build 主程序：`./cmd/server/`
- build collector：`./cmd/usage-collector/`
- runtime 复制 `CLIProxyAPI`、`cpa-usage-collector`、`railway.yaml`、`start.sh`
- `ENV DEPLOY=cloud`
- `CMD ["./start.sh"]`

完整内容：

```Dockerfile
FROM golang:1.26-alpine AS builder

WORKDIR /app

COPY go.mod go.sum ./

RUN go mod download

COPY . .

ARG VERSION=dev
ARG COMMIT=none
ARG BUILD_DATE=unknown

RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w -X 'main.Version=${VERSION}' -X 'main.Commit=${COMMIT}' -X 'main.BuildDate=${BUILD_DATE}'" -o ./CLIProxyAPI ./cmd/server/

RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o ./cpa-usage-collector ./cmd/usage-collector/

FROM alpine:3.23

RUN apk add --no-cache tzdata

RUN mkdir /CLIProxyAPI

COPY --from=builder ./app/CLIProxyAPI /CLIProxyAPI/CLIProxyAPI
COPY --from=builder ./app/cpa-usage-collector /CLIProxyAPI/cpa-usage-collector

COPY config.example.yaml /CLIProxyAPI/config.example.yaml
COPY railway.yaml /CLIProxyAPI/railway.yaml
COPY start.sh /CLIProxyAPI/start.sh

WORKDIR /CLIProxyAPI

RUN chmod +x start.sh

EXPOSE 8317

ENV TZ=Asia/Shanghai
ENV DEPLOY=cloud

RUN cp /usr/share/zoneinfo/${TZ} /etc/localtime && echo "${TZ}" > /etc/timezone

CMD ["./start.sh"]
```

### 4. 容器启动脚本

文件：`start.sh`

作用：
- 每次启动删除旧 `/CLIProxyAPI/config.yaml`。
- 从镜像内 `railway.yaml` 复制生成 `/CLIProxyAPI/config.yaml`。
- 若 `COLLECTOR_SECRET` 不为空，后台启动 `/CLIProxyAPI/cpa-usage-collector`。
- 最后用 `exec ./CLIProxyAPI` 让主程序成为容器前台进程。

完整内容：

```sh
#!/bin/sh
set -e

rm -f /CLIProxyAPI/config.yaml
cp /CLIProxyAPI/railway.yaml /CLIProxyAPI/config.yaml

# Best-effort: launch the usage collector in the background. A failure here
# (missing secret, write permission, etc.) must never block the proxy from
# starting, so we log to stdout and continue.
if [ -n "${COLLECTOR_SECRET}" ]; then
  echo "[start.sh] launching usage collector (output dir: ${COLLECTOR_OUTPUT_DIR:-/data/usage})"
  /CLIProxyAPI/cpa-usage-collector &
else
  echo "[start.sh] COLLECTOR_SECRET not set, usage collector disabled"
fi

exec ./CLIProxyAPI
```

### 5. Runtime 配置模板

文件：`railway.yaml`

必须保留：
- `port: 8080`，容器内主服务端口。
- `auth-dir: "/data/auth"`，auth 文件放到持久化数据卷。
- `remote-management.allow-remote: true`，collector 依赖 management API。
- `remote-management.secret-key: "railway-default-password"`，CPA `.env` 中 `COLLECTOR_SECRET` 必须匹配这个值，或同步修改。
- `usage-statistics-enabled: true`，不打开则 usage queue 没数据。
- `redis-usage-queue-retention-seconds: 600`，本地保留 10 分钟 queue 数据给 collector 拉取。
- `logging-to-file: true` 和日志限制。

完整内容：

```yaml
host: "0.0.0.0"
port: 8080
auth-dir: "/data/auth"
api-keys:
  - "railway-default-key"
debug: false
remote-management:
  allow-remote: true
  secret-key: "railway-default-password"
  disable-control-panel: false
usage-statistics-enabled: true
redis-usage-queue-retention-seconds: 600
logging-to-file: true
logs-max-total-size-mb: 500
error-logs-max-files: 50
```

### 6. Production Compose

文件：`docker-compose.yml`

必须保留：
- image 默认值为 `docker.cnb.cool/jung.ren/cliproxyapi:latest`。
- `.env` 可选加载。
- collector 环境变量。
- 主端口容器内映射到 `8080`，不是 upstream 旧的 `8317`。
- `/data` 和 `/CLIProxyAPI/logs` 两个 volume。
- `autoheal=true` label。
- healthcheck 使用 `wget -q --spider -T 4 http://127.0.0.1:8080/healthz`。
- `autoheal` sidecar。

完整内容：

```yaml
services:
  cli-proxy-api:
    image: ${APP_IMAGE:-docker.cnb.cool/jung.ren/cliproxyapi:latest}
    container_name: cli-proxy-api
    env_file:
      - path: ./.env
        required: false
    environment:
      DEPLOY: ${DEPLOY:-cloud}
      COLLECTOR_SECRET: ${COLLECTOR_SECRET:-}
      COLLECTOR_TARGET: ${COLLECTOR_TARGET:-http://127.0.0.1:8080}
      COLLECTOR_OUTPUT_DIR: ${COLLECTOR_OUTPUT_DIR:-/data/usage}
      COLLECTOR_INTERVAL: ${COLLECTOR_INTERVAL:-10s}
    ports:
      - "${CLI_PROXY_API_PORT:-8317}:8080"
      - "${CLI_PROXY_PORT_8085:-8085}:8085"
      - "${CLI_PROXY_PORT_1455:-1455}:1455"
      - "${CLI_PROXY_PORT_54545:-54545}:54545"
      - "${CLI_PROXY_PORT_51121:-51121}:51121"
      - "${CLI_PROXY_PORT_11451:-11451}:11451"
    volumes:
      - ${CLI_PROXY_DATA_PATH:-./data}:/data
      - ${CLI_PROXY_LOGS_PATH:-./logs}:/CLIProxyAPI/logs
    labels:
      - autoheal=true
    healthcheck:
      test: ["CMD-SHELL", "wget -q --spider -T 4 http://127.0.0.1:8080/healthz || exit 1"]
      interval: 20s
      timeout: 5s
      retries: 5
      start_period: 30s
    restart: unless-stopped

  autoheal:
    image: willfarrell/autoheal:1.2.0
    container_name: cli-proxy-api-autoheal
    restart: unless-stopped
    environment:
      AUTOHEAL_CONTAINER_LABEL: autoheal
      AUTOHEAL_INTERVAL: 30
      AUTOHEAL_START_PERIOD: 90
      AUTOHEAL_DEFAULT_STOP_TIMEOUT: 10
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
```

### 7. UAT Compose

文件：`docker-compose.uat.yml`

完整内容：

```yaml
services:
  cli-proxy-api-uat:
    image: ${APP_IMAGE:-docker.cnb.cool/jung.ren/cliproxyapi:latest}
    container_name: cli-proxy-api-uat
    restart: unless-stopped
    environment:
      DEPLOY: cloud
      COLLECTOR_SECRET: ${UAT_MGMT_SECRET:-railway-default-password}
      COLLECTOR_TARGET: http://127.0.0.1:8080
      COLLECTOR_OUTPUT_DIR: /data/usage
      COLLECTOR_INTERVAL: ${COLLECTOR_INTERVAL:-10s}
      COLLECTOR_BOOT_DELAY: ${COLLECTOR_BOOT_DELAY:-8s}
    ports:
      - "${UAT_HOST:-127.0.0.1}:${UAT_PORT:-13127}:8080"
    volumes:
      - ${UAT_DATA_PATH:-./data-uat}:/data
    mem_limit: 256m
    cpus: 1.0
```

### 8. Makefile 运维入口

文件：`Makefile`

完整内容：

```makefile
UAT_COMPOSE := docker compose -f docker-compose.uat.yml
PROD_COMPOSE := docker compose -f docker-compose.yml

.PHONY: help \
        uat-bootstrap uat-up uat-stop uat-restart uat-rm uat-logs uat-status uat-pull \
        prod-deploy prod-deploy-force prod-status prod-logs prod-app-logs prod-pull prod-rollback prod-backup

help:
	@printf '%s\n' \
	'== UAT (cli-proxy-api-uat) ==' \
	'uat-bootstrap     Copy production auth files into ./data-uat (one-time)' \
	'uat-up            Pull image and start cli-proxy-api-uat' \
	'uat-stop          Stop cli-proxy-api-uat' \
	'uat-restart       Restart cli-proxy-api-uat' \
	'uat-rm            Stop and remove cli-proxy-api-uat container' \
	'uat-logs          Tail cli-proxy-api-uat container logs (stdout)' \
	'uat-status        Show production + UAT container status' \
	'uat-pull          Pull latest image without restart' \
	'' \
	'== Production (cli-proxy-api) ==' \
	'prod-backup       Snapshot configs, image tag and container state' \
	'prod-pull         Pull latest image (no restart)' \
	'prod-deploy       Backup, pull, recreate ONLY if image digest changed' \
	'prod-deploy-force Backup, pull, ALWAYS recreate (use when compose/env changed)' \
	'prod-status       Show production container + healthcheck' \
	'prod-logs         Tail container stdout (collector + start.sh)' \
	'prod-app-logs     Tail application log file (./logs/main.log)' \
	'prod-rollback     One-shot rollback to most recent backup'

# ---------- UAT ----------

uat-bootstrap:
	@if [ ! -d ./data/auth ]; then echo "ERROR: ./data/auth not found; cannot seed UAT" && exit 1; fi
	mkdir -p ./data-uat/auth ./data-uat/usage
	cp -r ./data/auth/. ./data-uat/auth/
	@echo "auth files copied to ./data-uat/auth"

uat-up:
	mkdir -p ./data-uat ./data-uat/usage
	$(UAT_COMPOSE) pull
	$(UAT_COMPOSE) up -d

uat-stop:
	$(UAT_COMPOSE) stop

uat-restart:
	$(UAT_COMPOSE) restart

uat-rm:
	$(UAT_COMPOSE) down

uat-logs:
	docker logs --tail 200 -f cli-proxy-api-uat

uat-status:
	@docker ps -a --format '{{.Names}}\t{{.Status}}\t{{.Ports}}' | grep -E '^(cli-proxy-api-uat|cli-proxy-api)\b|^NAMES\b' || true

uat-pull:
	$(UAT_COMPOSE) pull

# ---------- Production ----------

prod-backup:
	sh ./scripts/backup.sh

prod-pull:
	$(PROD_COMPOSE) pull

prod-deploy:
	FORCE="$(FORCE)" sh ./scripts/deploy.sh

prod-deploy-force:
	FORCE=1 sh ./scripts/deploy.sh

prod-status:
	@docker ps -a --format '{{.Names}}\t{{.Status}}\t{{.Ports}}' | grep -E '^cli-proxy-api\b|^NAMES\b' || true
	@echo
	@docker inspect cli-proxy-api --format 'Health: {{.State.Health.Status}}' 2>/dev/null || true

prod-logs:
	docker logs --tail 200 -f cli-proxy-api

prod-app-logs:
	tail -F ./logs/main.log

prod-rollback:
	sh ./scripts/rollback.sh
```

### 9. 部署脚本

文件：`scripts/backup.sh`

完整内容：

```sh
#!/bin/sh
# Snapshot the live production setup before any deploy/upgrade.
#
# Captures, into /data/CLIProxyAPI/.backup/<timestamp>/:
#   - docker-compose.yml, railway.yaml, .env, Makefile, config.yaml (current files)
#   - container-inspect.json (full docker inspect of cli-proxy-api)
#   - git-head.txt, git-status.txt
#   - RESTORE.sh (a self-contained one-shot rollback script)
# Also retags the running production image as cliproxyapi-rollback:<timestamp>
# so it survives an `docker pull` overwrite of :latest.
set -e

REPO_DIR="${REPO_DIR:-/data/CLIProxyAPI}"
TS="$(date +%Y%m%d-%H%M%S)"
BAK="$REPO_DIR/.backup/$TS"
CONTAINER="${CONTAINER:-cli-proxy-api}"

mkdir -p "$BAK"
cd "$REPO_DIR"

# Config files (best-effort; a missing file is not fatal)
for f in docker-compose.yml railway.yaml .env Makefile config.yaml docker-compose.uat.yml; do
  [ -f "$f" ] && cp "$f" "$BAK/" || true
done

# Container state — only snapshot if the container exists
if docker inspect "$CONTAINER" >/dev/null 2>&1; then
  docker inspect "$CONTAINER" > "$BAK/container-inspect.json"
  CURRENT_IMAGE="$(docker inspect "$CONTAINER" --format '{{.Config.Image}}')"
  echo "$CURRENT_IMAGE" > "$BAK/current-image.txt"
  # Retag the image we are running so :latest can be overwritten without losing it
  docker tag "$CURRENT_IMAGE" "cliproxyapi-rollback:$TS"
fi

# Git state
git rev-parse HEAD > "$BAK/git-head.txt" 2>/dev/null || true
git status > "$BAK/git-status.txt" 2>/dev/null || true

# Self-contained restore script
cat > "$BAK/RESTORE.sh" <<RESTORE
#!/bin/sh
# Restore production to the state captured at $TS.
# Run from any directory.
set -e
SRC="$BAK"
REPO="$REPO_DIR"
cd "\$REPO"

echo "[rollback] stopping current containers"
docker compose -f docker-compose.yml down 2>/dev/null || true
docker compose -f docker-compose.uat.yml down 2>/dev/null || true

echo "[rollback] restoring files from \$SRC"
for f in docker-compose.yml railway.yaml .env Makefile config.yaml docker-compose.uat.yml; do
  [ -f "\$SRC/\$f" ] && cp -f "\$SRC/\$f" "\$REPO/\$f" || true
done

if [ -f "\$SRC/current-image.txt" ]; then
  ORIG_IMAGE="\$(cat "\$SRC/current-image.txt")"
  echo "[rollback] retagging cliproxyapi-rollback:$TS -> \$ORIG_IMAGE"
  docker tag "cliproxyapi-rollback:$TS" "\$ORIG_IMAGE"
fi

echo "[rollback] starting cli-proxy-api with restored compose"
docker compose -f docker-compose.yml up -d

sleep 5
docker ps --format '{{.Names}}\t{{.Status}}' | grep cli-proxy-api || true
RESTORE
chmod +x "$BAK/RESTORE.sh"

echo "=== backup created: $BAK ==="
ls -la "$BAK/"
echo
echo "Rollback with:  sh $BAK/RESTORE.sh"
```

文件：`scripts/deploy.sh`

完整内容：

```sh
#!/bin/sh
# Pull the latest cnb image. If pull fails or image digest is unchanged,
# the container is NOT recreated. Only when there is actually a new image
# will the container be restarted (with healthcheck wait).
#
# Use FORCE=1 sh scripts/deploy.sh to recreate the container even when
# the image digest is unchanged (useful when only docker-compose.yml or
# .env changed).
set -e

REPO_DIR="${REPO_DIR:-/data/CLIProxyAPI}"
IMAGE_REF="${IMAGE_REF:-docker.cnb.cool/jung.ren/cliproxyapi:latest}"
FORCE="${FORCE:-0}"
cd "$REPO_DIR"

echo "[deploy] step 1: backup current state"
sh "$REPO_DIR/scripts/backup.sh"
echo

echo "[deploy] step 2: ensure mount dirs exist"
mkdir -p ./logs ./data/auth ./data/usage

echo "[deploy] step 3: record current image id"
OLD_ID="$(docker image inspect "$IMAGE_REF" --format '{{.Id}}' 2>/dev/null || echo none)"
echo "  old: $OLD_ID"

echo "[deploy] step 4: docker compose pull"
if ! docker compose -f docker-compose.yml pull; then
  echo "[deploy] ERROR: pull failed, container NOT restarted"
  exit 1
fi

NEW_ID="$(docker image inspect "$IMAGE_REF" --format '{{.Id}}')"
echo "  new: $NEW_ID"

if [ "$OLD_ID" = "$NEW_ID" ] && [ "$FORCE" != "1" ]; then
  echo "[deploy] no image update, container NOT restarted"
  echo "[deploy] (run with FORCE=1 to recreate anyway, e.g. when compose/env changed)"
  exit 0
fi

if [ "$OLD_ID" = "$NEW_ID" ]; then
  echo "[deploy] image unchanged but FORCE=1, will recreate"
else
  echo "[deploy] image updated, will recreate"
fi

echo "[deploy] step 5: docker compose up -d (recreates the container)"
docker compose -f docker-compose.yml up -d

echo
echo "[deploy] step 6: wait for healthcheck (up to 90s)"
for i in $(seq 1 18); do
  STATE="$(docker inspect cli-proxy-api --format '{{.State.Health.Status}}' 2>/dev/null || echo unknown)"
  echo "  attempt $i: $STATE"
  if [ "$STATE" = "healthy" ]; then
    echo "[deploy] OK, container healthy"
    docker ps --format '{{.Names}}\t{{.Status}}' | grep cli-proxy-api
    exit 0
  fi
  sleep 5
done

echo "[deploy] WARNING: container not healthy after 90s"
echo "[deploy] tail of container logs:"
docker logs --tail 30 cli-proxy-api
echo
echo "[deploy] to roll back: sh $REPO_DIR/scripts/rollback.sh"
exit 1
```

文件：`scripts/rollback.sh`

完整内容：

```sh
#!/bin/sh
# Roll back to the most recent backup snapshot, or a specific one if passed.
#
# Usage:
#   scripts/rollback.sh                # use most recent
#   scripts/rollback.sh 20260508-043503  # use named timestamp
set -e

REPO_DIR="${REPO_DIR:-/data/CLIProxyAPI}"
TARGET="$1"

if [ -z "$TARGET" ]; then
  TARGET="$(ls -1t "$REPO_DIR/.backup" 2>/dev/null | head -1)"
fi

if [ -z "$TARGET" ]; then
  echo "ERROR: no backup found under $REPO_DIR/.backup" >&2
  exit 1
fi

BAK="$REPO_DIR/.backup/$TARGET"
RESTORE="$BAK/RESTORE.sh"

if [ ! -x "$RESTORE" ]; then
  echo "ERROR: $RESTORE not found or not executable" >&2
  echo "available backups:" >&2
  ls -1 "$REPO_DIR/.backup" 2>/dev/null >&2
  exit 1
fi

echo "rolling back from $BAK"
exec sh "$RESTORE"
```

### 10. 管理接口封禁阈值

文件：`internal/api/handlers/management/handler.go`

本地改动：
- `AuthenticateManagementKey` 内 `maxFailures` 从 `5` 改为 `50`。
- `banDuration` 仍为 `30 * time.Minute`。

必须恢复为：

```go
const maxFailures = 50
const banDuration = 30 * time.Minute
```

对应测试也要同步：
- `internal/api/handlers/management/handler_test.go` 中失败循环从 `5` 改为 `50`。
- `internal/api/redis_queue_protocol_integration_test.go` 中 Redis 协议相关失败循环从 `5` 改为 `50`，并把错误提示 attempt 编号从 `i+6` 改为 `i+51`。

精确改动：

```diff
-	const maxFailures = 5
+	const maxFailures = 50
```

```diff
-	for i := 0; i < 5; i++ {
+	for i := 0; i < 50; i++ {
```

```diff
-			t.Fatalf("unexpected AUTH banned error at attempt %d: %q", i+6, msg)
+			t.Fatalf("unexpected AUTH banned error at attempt %d: %q", i+51, msg)
```

### 11. `.gitignore`

必须保留 runtime 数据排除：

```gitignore
# Runtime / deploy data
data/
data-uat/
data-test/
.backup/
```

必须确保 `AGENTS.md` 和 `CLAUDE.md` 不再被 ignore。upstream 原先文档段里如果有这两行，需要删除：

```gitignore
AGENTS.md
CLAUDE.md
```

### 12. Docker 本地构建脚本

文件：`docker-build.sh`

必须保留：

```bash
export CLI_PROXY_IMAGE="eceasy/cli-proxy-api:latest"
```

以及本地构建 tag：

```bash
export CLI_PROXY_IMAGE="cliproxyapi-local:latest"
```

文件：`docker-build.ps1`

必须保留：

```powershell
$env:CLI_PROXY_IMAGE = "eceasy/cli-proxy-api:latest"
```

以及本地构建 tag：

```powershell
$env:CLI_PROXY_IMAGE = "cliproxyapi-local:latest"
```

### 13. Railway 文件

这些是早期 Railway 支持，不是当前 CPA 生产主路径，但属于本地改动。

文件：`railway.toml`

```toml
[build]
builder = "DOCKERFILE"
dockerfilePath = "Dockerfile"

[deploy]
startCommand = "./start.sh"
restartPolicyType = "ON_FAILURE"
restartPolicyMaxRetries = 10
```

文件：`RAILWAY_DEPLOY.md`

内容是 Railway 部署说明。功能恢复时它不是 CPA 生产强依赖，但属于本地改动，完整内容如下：

````markdown
# Railway 部署指南

## 快速部署

1. 在 Railway 创建新项目
2. 连接此 GitHub 仓库
3. Railway 会自动检测 Dockerfile 并开始构建
4. 部署完成后，Railway 会自动分配域名和端口

## 环境变量配置（可选）

在 Railway 项目设置中添加以下环境变量：

```
DEPLOY=cloud
```

Railway 会自动设置 `PORT` 环境变量，应用会自动使用该端口。

## 配置说明

- 默认端口：8317（Railway 会自动映射到分配的端口）
- 配置文件：使用 `config.example.yaml` 作为模板
- 认证目录：`/data/auth`

## 首次使用

部署成功后：

1. 访问 Railway 分配的域名
2. 使用管理 API 进行配置
3. 添加你的 API keys 和提供商配置

## 注意事项

- Railway 免费计划有使用限制
- 建议配置持久化存储（使用环境变量配置 Postgres/Git/Object Store）
- 生产环境建议设置 `MANAGEMENT_PASSWORD` 环境变量
````

### 14. 私有部署文档

文件：`AGENTS.md`

本地新增 `Private Deployment Notes`，必须至少保留以下信息：

```markdown
## Private Deployment Notes
- Detailed fork/deployment runbook lives in `CLAUDE.md`; check it before production operations.
- CNB image: `docker.cnb.cool/jung.ren/cliproxyapi:latest`; pushing `main` to `cnb` triggers image build.
- New API host: `118.89.239.190`; it also stores the cnb registry credential at `/root/.docker/config.json`.
- Shanghai ingress/jump host: `81.69.15.109`. Treat it as the only public CPA entrypoint, not the app data host.
- CPA Plus backend: `114.111.176.35:13100`; operations SSH uses `ssh -p 13100 root@81.69.15.109`.
- CPA Free backend: `114.111.176.35:5300`; operations SSH uses `ssh -p 5300 root@81.69.15.109`.
- Backend project path on each CPA: `/data/CLIProxyAPI`; production container: `cli-proxy-api`.
- Production compose includes `cli-proxy-api-autoheal`; keep the `autoheal=true` label and the `wget -T 4` healthcheck when editing compose.
- Usage collector is required; each CPA writes CSV files under `/data/CLIProxyAPI/data/usage/`.
- CPA Plus ingress forwards: `81.69.15.109:8317 -> 114.111.176.35:13117`, `81.69.15.109:8080 -> 114.111.176.35:13117`, `81.69.15.109:8085 -> 114.111.176.35:13185`, `81.69.15.109:1455 -> 114.111.176.35:13145`, `81.69.15.109:54545 -> 114.111.176.35:13154`, `81.69.15.109:51121 -> 114.111.176.35:13121`, `81.69.15.109:11451 -> 114.111.176.35:13151`.
- CPA Free ingress forwards: `81.69.15.109:5317 -> 114.111.176.35:5317`, `81.69.15.109:5385 -> 114.111.176.35:5385`, `81.69.15.109:5345 -> 114.111.176.35:5345`, `81.69.15.109:5354 -> 114.111.176.35:5354`, `81.69.15.109:5321 -> 114.111.176.35:5321`, `81.69.15.109:5351 -> 114.111.176.35:5351`; `5355` is intentionally avoided.
- Production deploy entrypoints on each CPA backend: `make prod-deploy`, `make prod-deploy-force`, `make prod-rollback`.
```

文件：`CLAUDE.md`

这是详细本地 fork 运维 runbook，完整文件较长。恢复功能时不是编译/运行强依赖，但生产运维强依赖。精确恢复方式：

```bash
git fetch origin main
git checkout 6d663b68 -- CLAUDE.md
```

如果不能从 git 恢复，至少要重建以下章节：
- 项目关系和远端说明。
- CNB 镜像和 Docker registry 说明。
- New API、上海跳板机、CPA Plus、CPA Free 拓扑。
- CPA Plus / CPA Free 端口转发表。
- 本地相对 upstream 的改动清单。
- upstream 合并流程。
- 日常开发、push、CNB build、服务器部署流程。
- UAT 和生产 deploy / rollback 操作手册。

## 服务器拓扑和端口

四台/四个角色：
- New API：`118.89.239.190`
- 上海跳板机：`81.69.15.109`
- CPA Plus：`114.111.176.35`，SSH 通过跳板机 `81.69.15.109:13100`
- CPA Free：`114.111.176.35`，SSH 通过跳板机 `81.69.15.109:5300`

CPA Plus：
- SSH：`ssh -p 13100 root@81.69.15.109`
- 后端路径：`/data/CLIProxyAPI`
- 入口映射：
- `81.69.15.109:8317 -> 114.111.176.35:13117`
- `81.69.15.109:8080 -> 114.111.176.35:13117`
- `81.69.15.109:8085 -> 114.111.176.35:13185`
- `81.69.15.109:1455 -> 114.111.176.35:13145`
- `81.69.15.109:54545 -> 114.111.176.35:13154`
- `81.69.15.109:51121 -> 114.111.176.35:13121`
- `81.69.15.109:11451 -> 114.111.176.35:13151`
- `81.69.15.109:13100 -> 114.111.176.35:13100`

CPA Free：
- SSH：`ssh -p 5300 root@81.69.15.109`
- 后端路径：`/data/CLIProxyAPI`
- 入口映射：
- `81.69.15.109:5317 -> 114.111.176.35:5317`
- `81.69.15.109:5385 -> 114.111.176.35:5385`
- `81.69.15.109:5345 -> 114.111.176.35:5345`
- `81.69.15.109:5354 -> 114.111.176.35:5354`
- `81.69.15.109:5321 -> 114.111.176.35:5321`
- `81.69.15.109:5351 -> 114.111.176.35:5351`
- `81.69.15.109:5300 -> 114.111.176.35:5300`

## CPA `.env` 示例

CPA Plus 的 `.env` 使用 13xxx 端口：

```dotenv
CLI_PROXY_API_PORT=13117
CLI_PROXY_PORT_8085=13185
CLI_PROXY_PORT_1455=13145
CLI_PROXY_PORT_54545=13154
CLI_PROXY_PORT_51121=13121
CLI_PROXY_PORT_11451=13151
COLLECTOR_SECRET=railway-default-password
```

CPA Free 的 `.env` 使用 53xx 端口：

```dotenv
CLI_PROXY_API_PORT=5317
CLI_PROXY_PORT_8085=5385
CLI_PROXY_PORT_1455=5345
CLI_PROXY_PORT_54545=5354
CLI_PROXY_PORT_51121=5321
CLI_PROXY_PORT_11451=5351
COLLECTOR_SECRET=railway-default-password
```

如修改 `railway.yaml` 中 `remote-management.secret-key`，必须同步修改 `.env` 的 `COLLECTOR_SECRET`，否则 collector 拉不到 usage。

## 恢复后的验证

本地验证：

```bash
gofmt -w cmd/usage-collector/main.go internal/api/handlers/management/handler.go internal/api/handlers/management/handler_test.go internal/api/redis_queue_protocol_integration_test.go
go build -o test-output ./cmd/server && rm -f test-output
go build -o test-output-collector ./cmd/usage-collector && rm -f test-output-collector
```

关键 grep：

```bash
grep -n "cpa-usage-collector\|start.sh" Dockerfile
grep -n "COLLECTOR_\|autoheal\|healthz\|/CLIProxyAPI/logs" docker-compose.yml
grep -n "usage-statistics-enabled\|redis-usage-queue-retention-seconds\|logging-to-file" railway.yaml
grep -n "maxFailures = 50" internal/api/handlers/management/handler.go
```

Docker 镜像验证：

```bash
docker build -t cliproxyapi-restore-test .
docker run --rm cliproxyapi-restore-test sh -lc 'test -x /CLIProxyAPI/CLIProxyAPI && test -x /CLIProxyAPI/cpa-usage-collector && test -f /CLIProxyAPI/railway.yaml && test -x /CLIProxyAPI/start.sh'
```

UAT 验证：

```bash
ssh -p 13100 root@81.69.15.109 'cd /data/CLIProxyAPI && make uat-up'
ssh -p 13100 root@81.69.15.109 'docker ps --format "{{.Names}}\t{{.Status}}" | grep cli-proxy-api-uat'
```

生产部署命令：

```bash
ssh -p 13100 root@81.69.15.109 'cd /data/CLIProxyAPI && make prod-deploy'
ssh -p 5300 root@81.69.15.109 'cd /data/CLIProxyAPI && make prod-deploy'
```

生产状态：

```bash
ssh -p 13100 root@81.69.15.109 'cd /data/CLIProxyAPI && make prod-status'
ssh -p 5300 root@81.69.15.109 'cd /data/CLIProxyAPI && make prod-status'
```

Usage 输出检查：

```bash
ssh -p 13100 root@81.69.15.109 'ls -lah /data/CLIProxyAPI/data/usage | tail'
ssh -p 5300 root@81.69.15.109 'ls -lah /data/CLIProxyAPI/data/usage | tail'
```

## 本地提交列表

这些是生成本文档时本地相对 upstream 的非 merge 提交。若 origin 仍保留这些提交，可以 cherry-pick 或 checkout 文件恢复。

```text
331226a3 Add Railway deployment support
59683b44 Fix: create config.yaml from example if not exists
edce3784 Enable remote management with default password
42fafe74 Force enable remote management
8def7a14 Use railway.yaml with secret-key configured
d66852d4 Add railway.yaml to Docker image
236f9680 Configure PostgreSQL storage
747d8507 Force recreate config.yaml on startup
baacc389 Debug: print config before start
40bb81d9 Add debug output for PORT
4dc20ca8 Set fixed port 8080
fff906af Fix Docker Compose runtime defaults
d6688b94 feat: add standalone usage collector that writes per-account CSV
1b7987ef ci: add cnb pipeline that builds and pushes Docker image on push
c44c0201 ops: add UAT compose stack and Makefile targets
a6a81d83 fix(usage-collector): use /v0/management/usage-queue path
194680b0 config: enable usage statistics and 10-min retention in railway.yaml
0214fbf2 ops: production deploy pipeline with backup, rollback, and persistent logs
7be6c73b fix(deploy): healthcheck uses /healthz with --spider for busybox wget
ad999c7b docs: add CLAUDE.md with fork-specific changes, deploy and merge runbooks
2ecaf18c ops: prod-deploy is no-op when image digest unchanged
d3cbcbfd docs: warn that pushing to cnb always rebuilds the image
f2f8225a Relax management ban threshold
64bf0bc4 Add Docker autoheal watchdog
d97a455c Document production ingress topology
6d663b68 Document CPA Free deployment topology
```
