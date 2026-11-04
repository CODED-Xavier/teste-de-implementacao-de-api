.DEFAULT_GOAL := help
EVENT ?= demo
QTY   ?= 100

.PHONY: help env up down logs test-local smoke seed k8s-up k8s-down k8s-status k8s-smoke k8s-seed loadtest validate

help: ## Lista os comandos
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n",$$1,$$2}'

env: ## Cria .env a partir de .env.example (se não existir)
	@test -f .env || (cp .env.example .env && echo ".env criado - EDITE as senhas antes de continuar")

# ---------- Docker Compose ----------
up: env ## Sobe tudo com Docker Compose
	docker compose up -d --build
down: ## Derruba o Compose (mantém volumes)
	docker compose down
logs: ## Logs das APIs
	docker compose logs -f flash-sales contratos
smoke: ## Smoke test no Compose
	MODE=compose ./scripts/smoke-test.sh
seed: ## Semeia estoque no Compose: make seed EVENT=demo QTY=100
	MODE=compose ./scripts/seed-stock.sh $(EVENT) $(QTY)

# ---------- Kubernetes (kind) ----------
k8s-up: env ## Cria cluster kind + deploy completo
	./scripts/k8s-up.sh
k8s-down: ## Destrói o cluster kind
	./scripts/k8s-down.sh
k8s-status: ## Pods, HPA e Services
	kubectl -n devops-project get pods,hpa,svc
k8s-smoke: ## Smoke test no Kubernetes
	MODE=k8s ./scripts/smoke-test.sh
k8s-seed: ## Semeia estoque no Kubernetes
	MODE=k8s ./scripts/seed-stock.sh $(EVENT) $(QTY)

# ---------- Qualidade ----------
test-local: ## Testes unitários das duas APIs (requer Node 22)
	cd apps/flash-sales && npm ci && npm run typecheck && npm test
	cd apps/contratos && npm ci && npm run typecheck && npm test
validate: ## Valida manifestos/compose (requer kubectl e docker)
	kubectl kustomize --load-restrictor=LoadRestrictionsNone k8s/overlays/local > /dev/null && echo "kustomize OK"
	docker compose --env-file .env.example config -q && echo "compose OK"
loadtest: ## Teste de carga com k6 (https://k6.io)
	k6 run scripts/loadtest.js
