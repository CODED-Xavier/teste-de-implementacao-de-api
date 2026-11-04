# Justificativa de Arquitetura

## 1. Contexto e o que a aplicação nos "pede"

A leitura do código orientou as decisões:

| Observação no código | Implicação na infraestrutura |
|---|---|
| Flash Sales: venda concorrente de ingressos com **Lua no Redis** (decremento atômico) | Redis é parte crítica: precisa de **persistência (AOF)** e readiness; qualquer nº de réplicas da API é seguro contra *overselling* |
| `POST /tickets/export` **bloqueia o event loop** e consome CPU/memória (intencional) | **Limites de recursos**, **múltiplas réplicas**, **HPA**, probes tolerantes e alerta de *event-loop lag* para que um pod ocupado não derrube o serviço |
| `/metrics` com Prometheus (histograma + métricas padrão Node) | Observabilidade pronta para ser coletada: Prometheus + Grafana + alertas |
| Configuração 100% por variáveis de ambiente (12-factor) | ConfigMap/Secret/`.env`; a mesma imagem roda em qualquer ambiente |
| Sem `/health`, sem `build/start`, falha de banco deixava o processo "vivo" | Adicionados health checks, scripts e *fail-fast* (ver README) |

## 2. Decisões e como atendem aos três pilares

### Escalabilidade
- **APIs stateless** → escalam horizontalmente. **HPA** (CPU 60%, 2–6 pods no Flash Sales; 2–4 no Contratos) reage a picos como o de uma venda relâmpago; `scaleUp` imediato e `scaleDown` com janela de 120 s evitam oscilação.
- **Requests/limits** em todos os pods: o scheduler distribui corretamente, o HPA tem base de cálculo e um pod com o endpoint pesado não consome o nó inteiro (`--max-old-space-size` abaixo do limite de memória para falhar de forma controlada).
- **topologySpreadConstraints** espalha réplicas entre nós.
- Estado isolado em Postgres/Redis (StatefulSets com PVC) — a camada de aplicação permanece descartável.

### Confiabilidade
- **Três probes com papéis distintos**: `startupProbe` (dá tempo de conectar ao banco), `readinessProbe` em `/ready` (só recebe tráfego com Postgres+Redis OK) e `livenessProbe` em `/health` (reinicia processo travado; tolerância de ~30 s para não matar pods durante um export legítimo).
- **Deploy sem downtime**: `RollingUpdate` com `maxUnavailable: 0` + `PodDisruptionBudget` (`minAvailable: 1`) + *graceful shutdown* (SIGTERM tratado, `tini` como PID 1).
- **Fail-fast + restart automático**: falha ao inicializar encerra o processo e o orquestrador reinicia.
- **Dependências ordenadas** no Compose via `healthcheck` + `depends_on: service_healthy`.
- **Persistência**: PVC para Postgres e Redis com AOF (o estoque de ingressos não se perde em restart).
- **Observabilidade e alertas**: dashboard (RPS, p95, 5xx, event-loop lag, CPU, memória) e regras para instância fora do ar, 5xx > 5%, p95 > 1 s, event loop bloqueado e memória alta.
- **Entrega verificada**: o CD só passa se o ambiente subir de verdade e o smoke test (incluindo a regra de esgotamento de estoque → 409) passar.

### Segurança
- **Imagens**: multi-stage (sem compiladores/devDependencies em produção), base Alpine, **usuário não-root**, versões fixadas (sem `latest` nas dependências de infra), scan **Trivy** bloqueando vulnerabilidades críticas e **Hadolint** no CI.
- **Pods**: `runAsNonRoot`, `readOnlyRootFilesystem`, `allowPrivilegeEscalation: false`, `capabilities: drop ALL`, `seccomp RuntimeDefault`; namespace com Pod Security `baseline`. No Compose: `read_only`, `cap_drop`, `no-new-privileges`.
- **Segredos fora do Git**: `.env` ignorado, `Secret` criado por script a partir dele, e no CD gerados aleatoriamente por execução. Compose falha se a senha não estiver definida (`:?`).
- **Menor privilégio**: Prometheus usa `Role` apenas de leitura de pods no próprio namespace; redes Docker separadas (`backend` x `observability`); bancos não são publicados no host.
- **Rastreabilidade**: imagens publicadas com tag imutável = SHA do commit.

## 3. Automação e entrega contínua
- **Infraestrutura como código**: tudo versionado (Compose, Kustomize, kind, dashboards, alertas). Dashboards/alertas têm **fonte única** consumida por Compose e Kubernetes.
- **Kustomize base + overlay**: a base é neutra; o overlay `local` só ajusta imagens e NodePorts. Um overlay `prod` (Ingress/LoadBalancer, réplicas, tags do registry) reutilizaria a base.
- **CI** (rápido feedback em cada push/PR) separado de **CD** (só `main`), com cache de build e `concurrency` para cancelar execuções obsoletas.
- **Reprodutibilidade**: `make k8s-up` recria o ambiente inteiro do zero; versões de kind, Kubernetes, metrics-server, Prometheus, Grafana, Postgres e Redis são fixadas.

## 4. Trade-offs assumidos

| Decisão | Por quê | Evolução para produção |
|---|---|---|
| kind em vez de nuvem | custo zero, reprodutível por qualquer integrante | EKS/GKE/AKS provisionado por Terraform |
| Postgres/Redis dentro do cluster, instância única | simplicidade didática | RDS/Cloud SQL e ElastiCache (HA, backup) ou operadores (CloudNativePG) |
| Um Postgres com 2 bancos / Redis compartilhado | menos recursos | instâncias por serviço |
| NodePort | acesso local simples | Ingress + TLS (cert-manager) |
| `synchronize: true` | já é o comportamento da aplicação | migrations versionadas executadas como Job no pipeline |
| Prometheus efêmero, sem Alertmanager | foco no essencial | kube-prometheus-stack, Alertmanager (Slack/e-mail), armazenamento persistente |
| Deploy imperativo no CD (apply) | simples | GitOps (Argo CD/Flux) com promoção dev → prod |
| Sem NetworkPolicy ativa | CNI do kind não aplica | default-deny + regras explícitas app → postgres/redis |

## 5. Risco conhecido de aplicação
`/tickets/export` aceita `records` arbitrário e é síncrono: um valor muito alto pode estourar a memória do pod (OOMKill). A infraestrutura **contém** o dano (limites, réplicas, PDB, alerta), mas a correção definitiva é de aplicação: processar em *worker*/fila, paginar/streamar o resultado e validar o limite de entrada.
