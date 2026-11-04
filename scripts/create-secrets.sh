#!/usr/bin/env bash
# Cria/atualiza o Secret "app-secrets" a partir do arquivo .env (nunca versionado).
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f .env ] || { echo "ERRO: .env não encontrado. Rode: make env"; exit 1; }
set -a; . ./.env; set +a
: "${DB_USER:?}" "${DB_PASSWORD:?}" "${GRAFANA_ADMIN_PASSWORD:?}"

kubectl create namespace devops-project --dry-run=client -o yaml | kubectl apply -f -
kubectl -n devops-project create secret generic app-secrets \
  --from-literal=DB_USER="$DB_USER" \
  --from-literal=DB_PASSWORD="$DB_PASSWORD" \
  --from-literal=GRAFANA_ADMIN_USER="${GRAFANA_ADMIN_USER:-admin}" \
  --from-literal=GRAFANA_ADMIN_PASSWORD="$GRAFANA_ADMIN_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -
echo "Secret app-secrets aplicado."
