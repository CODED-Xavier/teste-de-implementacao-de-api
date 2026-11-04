#!/usr/bin/env bash
# Define o estoque de ingressos de um evento no Redis (chave event:<id>:tickets).
# Uso: MODE=compose|k8s ./scripts/seed-stock.sh <eventId> <quantidade>
set -euo pipefail
cd "$(dirname "$0")/.."
EVENT="${1:?uso: seed-stock.sh <eventId> <quantidade>}"
QTY="${2:?uso: seed-stock.sh <eventId> <quantidade>}"
KEY="event:${EVENT}:tickets"

case "${MODE:-compose}" in
  compose) docker compose exec -T redis redis-cli SET "$KEY" "$QTY" ;;
  k8s)     kubectl -n devops-project exec statefulset/redis -- redis-cli SET "$KEY" "$QTY" ;;
  *) echo "MODE inválido (compose|k8s)"; exit 1 ;;
esac
