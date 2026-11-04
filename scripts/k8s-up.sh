#!/usr/bin/env bash
# Provisiona o ambiente Kubernetes local (kind) de ponta a ponta e é idempotente.
#   SKIP_BUILD=1  -> não builda as imagens (CI: já vieram do registry e foram tagueadas :local)
set -euo pipefail
cd "$(dirname "$0")/.."

CLUSTER=devops
METRICS_SERVER_VERSION=v0.7.2

echo "==> 1/6 Cluster kind"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  echo "cluster '$CLUSTER' já existe"
else
  kind create cluster --config k8s/kind-config.yaml --wait 120s
fi
kubectl config use-context "kind-$CLUSTER" >/dev/null

echo "==> 2/6 metrics-server (necessário para o HPA)"
kubectl apply -f "https://github.com/kubernetes-sigs/metrics-server/releases/download/${METRICS_SERVER_VERSION}/components.yaml"
# kind usa certificados autoassinados nos kubelets
kubectl -n kube-system patch deployment metrics-server --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]' 2>/dev/null || true

echo "==> 3/6 Imagens"
if [ "${SKIP_BUILD:-0}" != "1" ]; then
  docker build -t flash-sales:local apps/flash-sales
  docker build -t contratos:local apps/contratos
fi
kind load docker-image flash-sales:local contratos:local --name "$CLUSTER"

echo "==> 4/6 Secrets"
./scripts/create-secrets.sh

echo "==> 5/6 Deploy (Kustomize)"
kubectl kustomize --load-restrictor=LoadRestrictionsNone k8s/overlays/local | kubectl apply -f -

echo "==> 6/6 Aguardando rollout"
kubectl -n devops-project rollout status statefulset/postgres --timeout=180s
kubectl -n devops-project rollout status statefulset/redis --timeout=120s
for d in flash-sales contratos prometheus grafana; do
  kubectl -n devops-project rollout status deployment/$d --timeout=240s
done

cat <<MSG

Ambiente pronto:
  Flash Sales  http://localhost:3000
  Contratos    http://localhost:3001
  Grafana      http://localhost:3002
  Prometheus   http://localhost:9090
MSG
