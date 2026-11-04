# Infraestrutura DevOps — Flash Sales & Contratos

Infraestrutura, automação e entrega contínua para as duas APIs Node.js/TypeScript fornecidas
(**Flash Sales** e **Contratos**), ambas com PostgreSQL + Redis e métricas Prometheus em `/metrics`.

> A justificativa das decisões (escalabilidade, segurança, confiabilidade) está em
> [`docs/ARQUITETURA.md`](docs/ARQUITETURA.md).

## Visão geral

```
                      ┌────────────────────── Kubernetes (kind) · namespace devops-project ──────────────────────┐
 localhost:3000 ───►  │  flash-sales  (Deployment 2–6 pods, HPA CPU 60%, PDB, probes)  ──┐                        │
 localhost:3001 ───►  │  contratos    (Deployment 2–4 pods, HPA CPU 60%, PDB, probes)  ──┼──► postgres (StatefulSet+PVC)
                      │                                                                  └──► redis    (StatefulSet+AOF)
 localhost:9090 ───►  │  prometheus  ──(service discovery por anotação de pod)──► scrape /metrics + regras de alerta
 localhost:3002 ───►  │  grafana     (datasource e dashboard provisionados como código)                          │
                      └───────────────────────────────────────────────────────────────────────────────────────────┘

 Git push ─► CI (testes · build · Hadolint · Trivy · kubeconform · ShellCheck)
 merge main ─► CD (publica imagens no GHCR com tag = SHA ─► cluster efêmero ─► deploy ─► smoke test)
```

| Camada | Tecnologia |
|---|---|
| Contêineres | Docker (multi-stage, não-root, `tini`, `HEALTHCHECK`) |
| Ambiente local | Docker Compose |
| Orquestração | Kubernetes (kind) + Kustomize (base + overlay) |
| CI/CD | GitHub Actions + GHCR |
| Observabilidade | Prometheus (+ alertas) e Grafana provisionado |
| Testes | Jest (unitários), smoke test (bash), k6 (carga) |

## Estrutura do repositório

```
apps/flash-sales/        código da API + Dockerfile
apps/contratos/          código da API + Dockerfile
k8s/base/                manifestos Kubernetes (apps, bancos, monitoramento)
k8s/overlays/local/      overlay para kind (imagens locais, NodePorts)
k8s/kind-config.yaml     cluster kind (1 control-plane + 2 workers, portas mapeadas)
monitoring/              prometheus, alertas e dashboards Grafana (usados por Compose e K8s)
db/init-databases.sql    cria o segundo banco (contracts_db)
scripts/                 k8s-up/down, secrets, seed de estoque, smoke test, load test (k6)
.github/workflows/       ci.yml e cd.yml
docker-compose.yml       ambiente local completo
Makefile                 atalhos (make help)
```

## Pré-requisitos

- Docker 24+ com Compose v2
- Para Kubernetes: [`kind`](https://kind.sigs.k8s.io) e `kubectl` (1.28+)
- Opcional: Node 22 (testes locais) e [`k6`](https://k6.io) (carga)

## 1) Subir com Docker Compose (mais rápido)

```bash
make env          # cria .env a partir de .env.example  -> EDITE as senhas
make up           # build das imagens + sobe APIs, Postgres, Redis, Prometheus, Grafana
make smoke        # teste de fumaça ponta a ponta
```

| Serviço | URL |
|---|---|
| Flash Sales | http://localhost:3000 |
| Contratos | http://localhost:3001 |
| Prometheus | http://localhost:9090 |
| Grafana | http://localhost:3002 (usuário/senha do `.env`) |

Encerrar: `make down` (mantém dados) ou `docker compose down -v` (apaga volumes).

## 2) Provisionar no Kubernetes (kind)

```bash
make env                 # edite as senhas em .env
make k8s-up              # cria o cluster, instala metrics-server, builda/carrega imagens,
                         # cria Secrets, aplica os manifestos e aguarda o rollout
make k8s-status          # pods, HPA e services
make k8s-smoke           # teste de fumaça
make k8s-down            # destrói tudo
```

As mesmas portas do Compose são expostas em `localhost` (3000, 3001, 3002, 9090).
O `k8s-up.sh` é idempotente: pode ser executado novamente após mudanças.

## 3) Testar a API

**Flash Sales** — o estoque fica no Redis, então semeie antes de comprar:

```bash
make seed EVENT=show-2026 QTY=100           # Compose  (no K8s: make k8s-seed ...)

curl -X POST localhost:3000/checkout -H 'Content-Type: application/json' \
  -d '{"eventId":"show-2026","userId":"ana","quantity":2}'
# 201 {"message":"Checkout successful","order":{...}}   | 409 se esgotado | 400 se faltar campo

curl -X POST localhost:3000/tickets/export -H 'Content-Type: application/json' \
  -d '{"records":100000}'                    # endpoint pesado (bloqueia o event loop de propósito)
```

**Contratos**:

```bash
curl -X POST localhost:3001/contracts -H 'Content-Type: application/json' \
  -d '{"title":"Contrato A","userId":"ana","description":"teste","value":1500.50}'
# 201 | 400 se faltar title/userId
```

**Operação** (ambas as APIs): `GET /health` (liveness), `GET /ready` (readiness: Postgres + Redis), `GET /metrics`.

### Testes automatizados

```bash
make test-local                 # Jest nas duas APIs (Node 22)
make validate                   # renderiza Kustomize e valida o Compose
make loadtest                   # k6: rampa de checkouts + chamadas ao export
```

Para ver o autoscaling em ação durante o load test:

```bash
make k8s-seed EVENT=load QTY=1000000
make loadtest
kubectl -n devops-project get hpa -w      # em outro terminal
```
Acompanhe o dashboard **DevOps → APIs - Visão Geral** no Grafana e os alertas em http://localhost:9090/alerts.

## CI/CD

| Pipeline | Gatilho | O que faz |
|---|---|---|
| `ci.yml` | push (≠ main) e PR | build TypeScript, Jest, `npm audit`, Hadolint, build da imagem, Trivy (CRITICAL bloqueia), kubeconform, `compose config`, ShellCheck |
| `cd.yml` | merge na `main` | publica `ghcr.io/<owner>/<app>:<sha>` e `:latest`; sobe kind efêmero, implanta as imagens publicadas e roda o smoke test |

Não requer segredos manuais: usa `GITHUB_TOKEN`. Credenciais do ambiente efêmero são geradas na hora.
Em um repositório novo, habilite *Settings → Actions → Workflow permissions → Read and write*.

## Alterações mínimas feitas nas aplicações

| Arquivo | Mudança | Motivo |
|---|---|---|
| `package.json` | scripts `build`, `start`, `test`, `typecheck` | o original não tinha como compilar/rodar em produção nem executar os testes |
| `tsconfig.build.json` (novo) | `rootDir/outDir` | gera `dist/` sem afetar o `tsconfig` de desenvolvimento |
| `flash-sales/tsconfig.json` e `entities/Order.ts` | `experimentalDecorators`, `emitDecoratorMetadata` e `!` nos campos | mesma correção que já existe no Contratos; sem ela TypeORM/`tsc`/`ts-jest` falham |
| `controllers/HealthController.ts` + rotas | `/health` e `/ready` | probes de liveness/readiness |
| `server.ts` | `exit(1)` se o banco falhar; shutdown em SIGTERM | antes o processo ficava "vivo" sem servir; agora o orquestrador reinicia e faz deploy sem perda de requisições |

A lógica de negócio **não** foi alterada.

## Limitações conhecidas

- `synchronize: true` (TypeORM) cria o schema automaticamente: aceitável aqui, mas em produção deve ser substituído por *migrations*.
- Um único PostgreSQL (dois bancos) e um único Redis atendem às duas APIs; em produção, serviços gerenciados e HA.
- Não há autenticação nas APIs (fora do escopo fornecido).
- Prometheus usa armazenamento efêmero e não há Alertmanager (os alertas são avaliados e visíveis na UI).
- O `kind` não aplica `NetworkPolicy` (CNI padrão); veja evoluções em `docs/ARQUITETURA.md`.

## Troubleshooting

| Sintoma | Causa provável / solução |
|---|---|
| `/checkout` responde 409 sempre | estoque não semeado: `make seed EVENT=<id> QTY=<n>` |
| `kubectl top`/HPA mostram `<unknown>` | metrics-server ainda subindo (~1 min); `kubectl -n kube-system get pods` |
| Porta 3000/3001/3002/9090 ocupada | pare o outro ambiente (`make down` ou `make k8s-down`) — Compose e kind usam as mesmas portas |
| Pod `CrashLoopBackOff` no início | banco ainda inicializando; `startupProbe` e `exit(1)` fazem retry automático |
| `.env não encontrado` | `make env` |
