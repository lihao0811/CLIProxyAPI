UAT_COMPOSE := docker compose -f docker-compose.uat.yml

.PHONY: help uat-up uat-stop uat-restart uat-rm uat-logs uat-status uat-pull uat-bootstrap

help:
	@printf '%s\n' \
	'uat-bootstrap     Copy production auth files into ./data-uat (one-time)' \
	'uat-up            Pull image and start cli-proxy-api-uat' \
	'uat-stop          Stop cli-proxy-api-uat' \
	'uat-restart       Restart cli-proxy-api-uat' \
	'uat-rm            Stop and remove cli-proxy-api-uat container' \
	'uat-logs          Tail cli-proxy-api-uat logs' \
	'uat-status        Show production + UAT container status' \
	'uat-pull          Pull latest image without restart'

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
