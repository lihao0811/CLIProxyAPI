# CLAUDE.md

> 给 Claude Code / 其他 AI 助手看的本地 fork 项目说明。
> 注意：仓库根的 `AGENTS.md` 是 upstream 维护的（codex 默认读它），不要修改。
> 本地 fork 的所有改动、部署流程、运维信息**只在本文件**。如果用 codex 让它干活，请手动让它额外读这个文件。

## 1. 项目关系

这是 [`router-for-me/CLIProxyAPI`](https://github.com/router-for-me/CLIProxyAPI) 的私有 fork。
- upstream 频繁更新，**我们的策略是跟随 upstream 主干，不修改 upstream 文件**
- 本地新增的功能全部以**新增文件**或**外挂程序**方式存在，最大限度避免合并冲突
- 必须修改 upstream 文件的地方（如 Dockerfile / docker-compose.yml）已经分叉过，合并时会冲突，需手工解决（详见 §3、§4）


## 2. 远端 / 镜像

### Git 远端
| 名称 | URL | 用途 |
|---|---|---|
| `upstream` | https://github.com/router-for-me/CLIProxyAPI.git | 拉 upstream 更新（**只 fetch，不 push**） |
| `origin` | git@github.com:lihao0811/CLIProxyAPI.git | 私人主仓库（GitHub） |
| `cnb` | https://cnb.cool/jung.ren/CLIProxyAPI | 镜像，**push 触发 CI 自动 build docker 镜像** |

### Docker 镜像
- Registry：`docker.cnb.cool/jung.ren/cliproxyapi:latest`
- 由 cnb 自动构建（见 `.cnb.yml`），每次 push main 触发
- 服务器只 `docker pull`，**不在生产服务器上 build**
- 服务器 docker login 凭据：从 `118.89.239.190:~/.docker/config.json` 复制（cnb personal access token）

### 生产服务器
- IP / 端口：`81.69.15.109` ssh 端口 13100
- 项目目录：`/data/CLIProxyAPI/`
- 容器名：`cli-proxy-api`
- Volume 挂载（**全部持久化到 host**）：
  - `./data` ↔ 容器 `/data`（auth 文件 + collector CSV 输出）
  - `./logs` ↔ 容器 `/CLIProxyAPI/logs`（应用日志，`logging-to-file: true` 必须）
- 主端口：13117（OpenAI 兼容 / management / 伪 Redis 协议）


## 3. 本地相对 upstream 的改动清单（合并时检查）

合并 upstream 时**对照本节清单逐项检查**。任何被 upstream 同名文件覆盖、删除的，都要立刻恢复。

### 3.1 新增文件（upstream 没有，**绝不能丢**）

| 文件 / 目录 | 作用 | 合并时风险 |
|---|---|---|
| `cmd/usage-collector/main.go` | **核心新功能**：外挂 usage 收集器，poll `/v0/management/usage-queue` 写每账号 CSV | upstream 无 → 不会被覆盖。但要警惕 upstream 引入同名 cmd 子目录 |
| `start.sh` | 容器启动脚本：复制 `railway.yaml`→`config.yaml`，后台拉起 collector，前台跑主进程 | upstream 没有，但 Dockerfile 引用了它 |
| `railway.yaml` | 容器启动时拷贝为 `config.yaml`。包含 `logging-to-file/usage-statistics-enabled/redis-usage-queue-retention-seconds` 等关键开关 | 必须包含这几个开关，否则日志/usage 都不工作 |
| `railway.toml` | Railway 平台部署元信息（早期） | 与 fly.io / railway.app 集成相关 |
| `RAILWAY_DEPLOY.md` | Railway 部署文档（早期） | 仅文档 |
| `Makefile` | `uat-* / prod-*` target，统一运维入口 | upstream 无 |
| `docker-compose.uat.yml` | UAT 环境 compose（端口 13127、独立 data-uat 卷） | upstream 无 |
| `scripts/backup.sh` | 部署前备份配置 + 容器 inspect + 镜像 retag + 生成 RESTORE.sh | upstream 无 |
| `scripts/deploy.sh` | 一键部署：备份 → pull → up -d → 等 healthcheck | upstream 无 |
| `scripts/rollback.sh` | 一键回滚到最近一次备份 | upstream 无 |
| `.cnb.yml` | cnb CI 构建配置 | upstream 无 |
| `CLAUDE.md` / `AGENTS.md` | 本文件 | upstream 无 |

### 3.2 修改的 upstream 文件（合并冲突高发区）

合并 upstream 时这些文件**几乎必然冲突**，每次都要 manual 处理。

#### `Dockerfile`
本地新增内容（合并时务必保留）：
- builder 阶段额外一行：`RUN ... go build -o ./cpa-usage-collector ./cmd/usage-collector/`
- 运行阶段额外 COPY：`cpa-usage-collector` / `railway.yaml` / `start.sh`
- 运行阶段 `RUN chmod +x start.sh`
- `ENV DEPLOY=cloud`
- `CMD ["./start.sh"]`（**不是** `CMD ["./CLIProxyAPI"]`，upstream 默认是后者）

#### `docker-compose.yml`
本地特性（合并时务必保留）：
- `image:` 用 `${APP_IMAGE:-docker.cnb.cool/jung.ren/cliproxyapi:latest}`，**不要用 upstream 默认的 `eceasy/cli-proxy-api:latest`**
- 移除 `build:` 段（生产从 cnb 拉镜像，不本地 build）
- `env_file: - path: ./.env required: false`
- `environment:` 包含 `COLLECTOR_*` 5 个变量
- `ports:` 全部用 `${CLI_PROXY_*_PORT:-默认}` 形式
- `volumes:` 必须有两条：`data:/data` 和 `logs:/CLIProxyAPI/logs`（**logs 挂载是日志持久化的关键，丢了就重蹈覆辙**）
- `healthcheck:` 用 `wget -q --spider http://127.0.0.1:8080/healthz`（busybox 兼容）

#### `docker-build.sh`
- case 1 加了 `export CLI_PROXY_IMAGE="eceasy/cli-proxy-api:latest"`
- case 2 镜像 tag 改成 `cliproxyapi-local:latest`（**不是** upstream 的 `cli-proxy-api:local`）

#### `docker-build.ps1`
PowerShell 版本（不常用），保持与 `docker-build.sh` 一致即可。

#### `.gitignore`
本地新增的排除规则：`data/` `data-uat/` `data-test/` `.backup/`。
合并时检查这几行是否还在。CLAUDE.md / AGENTS.md 不能在 ignore 里。


## 4. 同步 upstream 的标准流程

<!-- 内容补充中 -->

> **核心原则**：合并不只是消除冲突，还要确保**本地功能没被 upstream 的隐性改动悄悄打破**（路由路径改了、字段重命名了、helper 函数移到别的包了等）。
> 流程分三阶段：**预检 → 合并 → 复检**，缺一不可。

### 阶段 A：预检（merge 之前）

#### A.1 抓 upstream，看领先量
```sh
git fetch upstream
git log --oneline main..upstream/main | wc -l
git log --oneline main..upstream/main         # 浏览所有 commit 标题
```

#### A.2 列出 upstream 改了哪些文件
```sh
git diff --name-status main..upstream/main > /tmp/upstream-changes.txt
wc -l /tmp/upstream-changes.txt
```

#### A.3 列出本地改了 upstream 哪些文件（§3.2 清单的源头）
```sh
git diff --name-status upstream/main..main | grep '^M' > /tmp/local-mods.txt
git diff --name-status upstream/main..main | grep '^A' > /tmp/local-adds.txt
```

#### A.4 求交集 = 必须人工逐行 review 的"高风险文件"
```sh
join \
  <(awk '{print $2}' /tmp/upstream-changes.txt | sort) \
  <(awk '{print $2}' /tmp/local-mods.txt        | sort) \
  > /tmp/risk-list.txt
cat /tmp/risk-list.txt
```
正常情况下交集就是 §3.2 那几个文件。**如果交集多了新文件，先在 merge 前搞清楚**。

#### A.5 扫一遍 upstream 重构高危关键词
本地 collector / start.sh / railway.yaml 依赖 upstream 的特定 API（如 `/v0/management/usage-queue`、配置字段名、`usage.Record` 结构）。upstream 重构这些**不会触发文件冲突，但运行时会出 bug**。

```sh
git log -p main..upstream/main -- \
  internal/api/server.go \
  internal/redisqueue/ \
  internal/api/handlers/management/usage.go \
  sdk/cliproxy/usage/ \
  internal/config/config.go \
  | grep -E "usage-queue|usage-statistics-enabled|redis-usage-queue|logging-to-file|UsageRecord|RegisterPlugin|/healthz"
```

预检阶段完成后，**用一句话写下"本次合并我担心什么"**（比如"upstream 把 /usage-queue 改成了 /usage 那 collector 会失效"），到阶段 C 一一验证。

### 阶段 B：合并

#### B.1 备份当前 main
```sh
git branch backup/main-before-merge-$(date +%Y%m%d-%H%M%S) main
```

#### B.2 merge（保留 merge commit 便于追溯，不要 rebase）
```sh
git merge upstream/main --no-edit
```

#### B.3 解决冲突
对照 §3.2 处理每个冲突文件：
- 保留本地的"加项"
- 吸收 upstream 的"非冲突改进"
- 注意 upstream 可能把某段代码改写得很彻底，需要把本地加项**重新嫁接**到新结构上

```sh
git add <冲突文件>
git commit                      # 完成 merge commit
```

### 阶段 C：复检（merge 之后，**最关键**）

#### C.1 对照 §3 清单逐项过一遍

新增文件全都还在？修改文件的"加项"全都保留？

```sh
# 新增文件存在性
ls cmd/usage-collector/main.go start.sh railway.yaml railway.toml \
   docker-compose.uat.yml Makefile scripts/{backup,deploy,rollback}.sh .cnb.yml

# Dockerfile / docker-compose.yml 关键加项
grep -n "cpa-usage-collector\|start.sh" Dockerfile
grep -n "COLLECTOR_\|/CLIProxyAPI/logs\|healthz" docker-compose.yml

# railway.yaml 关键开关
grep -E "usage-statistics-enabled|logging-to-file|redis-usage-queue" railway.yaml
```

#### C.2 编译

```sh
go build ./...                      # 主程序通过
go build ./cmd/usage-collector/     # collector 通过
                                    # 任一 import 路径变了就编不过
```

#### C.3 验证 upstream 重构的影响（针对 A.5 的担心）

| 担心 | 怎么验 |
|---|---|
| `/usage-queue` 路由变了？ | `grep -n "usage-queue" internal/api/server.go` 看路由现在挂在哪 |
| `usage-statistics-enabled` 字段重命名？ | `grep -n "usage-statistics-enabled" internal/config/config.go` |
| `redisqueue` 包重构？ | `ls internal/redisqueue/` 是否还存在，导出函数签名是否变了 |
| `usage.Record` 字段改名？ | 对照 `sdk/cliproxy/usage/manager.go` 与本地 `cmd/usage-collector/main.go` 的字段 |
| `logging-to-file` 行为改了？ | `grep -A 5 "LoggingToFile" internal/logging/global_logger.go` |

任何不一致都要修复 collector / railway.yaml / docker-compose.yml。

#### C.4 在 UAT 验证（**强烈建议，不省略**）

```sh
ssh -p 13100 root@81.69.15.109 'cd /data/CLIProxyAPI && \
  docker compose -f docker-compose.uat.yml pull && \
  docker compose -f docker-compose.uat.yml up -d'
# 调一次 chat completions，等 12s，看 data-uat/usage/ 有没有 CSV
# 通过才进生产部署
```

### 阶段 D：push 顺序

```sh
git push origin main          # GitHub 主仓
git push cnb main             # 触发 cnb CI build 新镜像
git push "ssh://root@81.69.15.109:13100/data/CLIProxyAPI" main   # 服务器同步代码
```

合并流程到此结束。后续在 UAT 验证通过后，通过 `sh scripts/deploy.sh`（§6.1）切生产。





## 5. 日常开发流程

不涉及 upstream 同步、纯本地改代码的情况。

### 5.1 改完代码 → 上线 4 步

```sh
# 1. 本地改代码、跑编译
go build ./...

# 2. commit + 三推送
git add <files>
git commit -m "<msg>"
git push origin main && git push cnb main && \
  git push "ssh://root@81.69.15.109:13100/data/CLIProxyAPI" main

# 3. 等 cnb 自动 build 镜像（约 1-3 分钟）
#    可选：观察镜像 digest 变化
ssh -p 13100 root@81.69.15.109 'docker pull docker.cnb.cool/jung.ren/cliproxyapi:latest'

# 4. 服务器执行部署（自动 backup + pull + recreate + healthcheck）
ssh -p 13100 root@81.69.15.109 'cd /data/CLIProxyAPI && sh scripts/deploy.sh'
```

### 5.2 仅改 docker-compose.yml / Makefile / scripts（不重 build 镜像）

跳过等待 cnb，因为镜像内容没变：
```sh
# push 后直接部署
ssh -p 13100 root@81.69.15.109 'cd /data/CLIProxyAPI && sh scripts/deploy.sh'
```

### 5.3 三个远端的角色总结

| 远端 | 作用 | push 必须？ |
|---|---|---|
| `origin` | 代码备份 | 是 |
| `cnb` | 触发 docker 镜像 CI build | 是（涉及代码改动时） |
| 服务器（裸仓库 push） | 同步代码到 `/data/CLIProxyAPI` 工作区 | 是 |

服务器上配置了 `git config receive.denyCurrentBranch updateInstead`，可直接 push 到工作区。


## 6. 部署操作手册

> **入口统一是 `make`，不要直接 sh 脚本。** 服务器上要先 `apt install make`（一次性）。
> `scripts/*.sh` 仅作 Makefile 的实现，故障兜底时才直接调（如 make 自己挂了）。
> 所有命令都在 `/data/CLIProxyAPI` 目录下执行。
> `make help` 永远是最权威的命令清单——半年后忘记了，先打这个。

### 6.1 生产部署（智能：没更新就不重启）
```sh
make prod-deploy
```
做的事：
1. `make prod-backup` 创建 `.backup/<时间戳>/` 快照
2. `mkdir -p logs data/auth data/usage`
3. `docker compose pull`
4. **比较 image digest**：没变化 → 立即结束，**不重启**；有变化 → 继续
5. `docker compose up -d` recreate
6. 轮询 healthcheck（最多 90s）

强制重启（即使镜像没变，比如改了 docker-compose.yml / .env）：
```sh
make prod-deploy-force
```

### 6.2 回滚

```sh
make prod-rollback                                              # 最近一次备份
sh scripts/rollback.sh 20260508-043503                          # 指定时间戳（make 没参数语法时退化到脚本）
sh /data/CLIProxyAPI/.backup/<时间戳>/RESTORE.sh                  # 备份目录自带的 RESTORE.sh，独立可用
```

### 6.3 备份 / 状态 / 日志

```sh
make prod-backup       # 单独打个快照
make prod-status       # 容器状态 + healthcheck
make prod-logs         # 容器 stdout（collector + start.sh）
make prod-app-logs     # tail -F ./logs/main.log（应用主日志）
```

### 6.4 UAT（独立隔离环境，端口 13127）

```sh
make uat-bootstrap     # 第一次：复制生产 auth 到 data-uat
make uat-up            # 启动
make uat-status        # 看状态
make uat-logs          # 看日志
make uat-stop          # 停（生产不受影响）
make uat-rm            # 删除容器
```

### 6.5 看消费数据

| 想看什么 | 命令 |
|---|---|
| 每条调用的账号/token CSV | `cat /data/CLIProxyAPI/data/usage/*.csv` |
| 应用日志（持久化） | `make prod-app-logs` |
| 错误请求详情 | `ls /data/CLIProxyAPI/logs/error-*` |
| 健康状态 | `make prod-status` |


## 7. 重要路径速查

### 服务器侧（`81.69.15.109:13100`）

| 路径 | 说明 |
|---|---|
| `/data/CLIProxyAPI/` | 项目目录，等同于 git 仓库根 |
| `/data/CLIProxyAPI/.env` | 端口映射 + `COLLECTOR_SECRET=railway-default-password`（**不进仓库**） |
| `/data/CLIProxyAPI/data/auth/` | OAuth 认证文件（**不进仓库，敏感**） |
| `/data/CLIProxyAPI/data/usage/` | collector CSV 输出，按账号 email 分文件 |
| `/data/CLIProxyAPI/logs/main.log` | 应用主日志（500MB 自动清理） |
| `/data/CLIProxyAPI/logs/error-*.log` | 错误请求详情（最多 50 个） |
| `/data/CLIProxyAPI/.backup/<ts>/` | 部署前快照 + RESTORE.sh |
| `~/.docker/config.json` | cnb registry 登录凭据 |

### 关键运行时配置

`railway.yaml`（容器启动时拷贝为 `config.yaml`）：
| 字段 | 当前值 | 说明 |
|---|---|---|
| `host` / `port` | `0.0.0.0` / `8080` | 容器内监听 |
| `auth-dir` | `/data/auth` | OAuth 文件位置 |
| `api-keys` | `[railway-default-key]` | 客户端 API key |
| `remote-management.secret-key` | `railway-default-password` | management secret，也用作 collector / Redis RESP 鉴权 |
| `usage-statistics-enabled` | `true` | **关 → collector 拿不到数据** |
| `redis-usage-queue-retention-seconds` | `600` | 内存队列保留 10 分钟 |
| `logging-to-file` | `true` | **关 → 日志只走 stdout，重启就丢** |
| `logs-max-total-size-mb` | `500` | 日志总量上限 |
| `error-logs-max-files` | `50` | 错误日志保留个数 |

### 端口映射（`.env` 控制）

| 容器端口 | 宿主机端口 | 用途 |
|---|---|---|
| 8080 | 13117 | OpenAI 兼容 / management / 伪 Redis（**主端口**） |
| 1455 | 13145 | gemini-cli 协议 |
| 8085 | 13185 | （备用） |
| 11451 | 13151 | （备用） |
| 51121 | 13121 | （备用） |
| 54545 | 13154 | （备用） |


## 8. 新开发机首次设置

> 本仓库不存任何机密文件 / 二进制 / 数据卷。换机器只要 git clone 即可。

```sh
# 1. clone
git clone git@github.com:lihao0811/CLIProxyAPI.git
cd CLIProxyAPI

# 2. 配三个远端
git remote add upstream https://github.com/router-for-me/CLIProxyAPI.git
git remote add cnb https://cnb.cool/jung.ren/CLIProxyAPI
# origin 是 clone 时自动设置的

# 3. 验证
git remote -v
git fetch --all

# 4. 装 Go（建议 1.26+）
go version

# 5. 编译验证
go build ./...
go build -o /tmp/cpa-usage-collector ./cmd/usage-collector/
```

### 不进仓库的东西（机器无关 / 机密）

| 项 | 哪里来 |
|---|---|
| 服务器 `.env` | 在生产服务器 `/data/CLIProxyAPI/.env`，必要时 ssh 上去 cat 出来 |
| 服务器 auth 文件 | 在 `/data/CLIProxyAPI/data/auth/`，敏感不要本地化 |
| `~/.docker/config.json`（连 cnb） | `ssh root@118.89.239.190 'cat ~/.docker/config.json'` 取，scp 到目标机器 |
| 备份目录 `.backup/` | 仅在生产服务器，**不要**复制到开发机 |

### 给 AI 助手的提示

如果你（Claude / Codex / 其他）正在阅读这份文档，关键约束：
1. **不要修改 upstream 的源码文件**（`internal/`、`sdk/`、`cmd/server/` 等），只能新增文件或修改 §3.2 列出的几个文件
2. 修改 `Dockerfile`/`docker-compose.yml` 时对照 §3.2 检查不要丢任何"加项"
3. `cmd/usage-collector/main.go` 是核心新功能，任何改动都要保证 `go build` 通过
4. 部署涉及生产服务器时，先备份再操作（`sh scripts/backup.sh`），并主动提醒用户确认重启时机
5. `CLAUDE.md` 改动时同步改 `AGENTS.md`（两者内容一致）

