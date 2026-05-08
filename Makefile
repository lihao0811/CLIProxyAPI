UAT_COMPOSE := docker compose -f docker-compose.uat.yml
PROD_COMPOSE := docker compose -f docker-compose.yml

.PHONY: help \
        uat-bootstrap uat-up uat-stop uat-restart uat-rm uat-logs uat-status uat-pull \
        prod-deploy prod-status prod-logs prod-app-logs prod-pull prod-rollback prod-backup

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
	'prod-pull         Pull latest image without restart' \
	'prod-deploy       Backup, pull, recreate, wait for healthcheck' \
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
	sh ./scripts/deploy.sh

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
