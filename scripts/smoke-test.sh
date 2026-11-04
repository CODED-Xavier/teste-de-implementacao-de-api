#!/usr/bin/env bash
# Teste de fumaça ponta a ponta das duas APIs (health, regra de negócio, métricas).
# Uso: MODE=compose|k8s ./scripts/smoke-test.sh
set -uo pipefail
cd "$(dirname "$0")/.."

FLASH="${FLASH_URL:-http://localhost:3000}"
CONTR="${CONTRATOS_URL:-http://localhost:3001}"
EVENT="smoke-$(date +%s)"
FAIL=0

status() { curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$@"; }
check() { # descrição esperado obtido
  if [ "$2" = "$3" ]; then echo "  [ OK ] $1"; else echo "  [FAIL] $1 (esperado $2, obtido $3)"; FAIL=1; fi
}
wait_ready() {
  for _ in $(seq 1 60); do
    [ "$(status "$1/ready")" = "200" ] && return 0
    sleep 2
  done
  return 1
}
post() { status -X POST -H 'Content-Type: application/json' -d "$2" "$1"; }

echo "==> Aguardando readiness"
wait_ready "$FLASH" || { echo "flash-sales não ficou pronto"; exit 1; }
wait_ready "$CONTR" || { echo "contratos não ficou pronto"; exit 1; }

echo "==> Flash Sales"
check "GET /health"  200 "$(status "$FLASH/health")"
check "GET /metrics" 200 "$(status "$FLASH/metrics")"
./scripts/seed-stock.sh "$EVENT" 2 >/dev/null
check "checkout 2 ingressos (estoque 2)"        201 "$(post "$FLASH/checkout" "{\"eventId\":\"$EVENT\",\"userId\":\"u1\",\"quantity\":2}")"
check "checkout 1 ingresso (esgotado) -> 409"   409 "$(post "$FLASH/checkout" "{\"eventId\":\"$EVENT\",\"userId\":\"u2\",\"quantity\":1}")"
check "checkout sem campos obrigatórios -> 400" 400 "$(post "$FLASH/checkout" '{"eventId":"x"}')"
check "métrica http_request_duration_ms exposta" yes "$(curl -s "$FLASH/metrics" | grep -q '^http_request_duration_ms' && echo yes || echo no)"

echo "==> Contratos"
check "GET /health"  200 "$(status "$CONTR/health")"
check "GET /metrics" 200 "$(status "$CONTR/metrics")"
check "criar contrato -> 201" 201 "$(post "$CONTR/contracts" '{"title":"Contrato Smoke","userId":"u1","description":"teste","value":1500.50}')"
check "contrato sem título -> 400" 400 "$(post "$CONTR/contracts" '{"userId":"u1"}')"

echo
if [ $FAIL -eq 0 ]; then echo "SMOKE TEST: SUCESSO"; else echo "SMOKE TEST: FALHOU"; fi
exit $FAIL
