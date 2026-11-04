// Teste de carga (k6). Demonstra escalabilidade (HPA) e o impacto do endpoint bloqueante.
//   k6 run scripts/loadtest.js
//   docker run --rm -i --network host -e EVENT_ID=load grafana/k6 run - < scripts/loadtest.js
// Pré-requisito: semear estoque ->  make seed EVENT=load QTY=1000000
import http from "k6/http";
import { check } from "k6";

const FLASH = __ENV.FLASH_URL || "http://localhost:3000";
const EVENT = __ENV.EVENT_ID || "load";

// 201 (comprado) e 409 (esgotado) são respostas válidas do negócio, não falhas.
http.setResponseCallback(http.expectedStatuses(201, 409, 200));

export const options = {
  scenarios: {
    checkout: {
      executor: "ramping-arrival-rate",
      exec: "checkout",
      startRate: 20,
      timeUnit: "1s",
      preAllocatedVUs: 100,
      maxVUs: 400,
      stages: [
        { target: 100, duration: "1m" },
        { target: 300, duration: "2m" },
        { target: 0, duration: "30s" },
      ],
    },
    // Chamadas ao endpoint que bloqueia o event loop: mostra consumo de CPU/memória e o HPA reagindo.
    export: {
      executor: "constant-arrival-rate",
      exec: "exportReport",
      rate: 1,
      timeUnit: "5s",
      duration: "3m",
      preAllocatedVUs: 5,
      startTime: "30s",
    },
  },
  thresholds: {
    "http_req_failed{scenario:checkout}": ["rate<0.01"],
    "http_req_duration{scenario:checkout}": ["p(95)<1500"],
  },
};

export function checkout() {
  const res = http.post(
    `${FLASH}/checkout`,
    JSON.stringify({ eventId: EVENT, userId: `user-${__VU}-${__ITER}`, quantity: 1 }),
    { headers: { "Content-Type": "application/json" } }
  );
  check(res, { "status 201 ou 409": (r) => r.status === 201 || r.status === 409 });
}

export function exportReport() {
  const res = http.post(
    `${FLASH}/tickets/export`,
    JSON.stringify({ records: 200000 }),
    { headers: { "Content-Type": "application/json" }, timeout: "60s" }
  );
  check(res, { "export 200": (r) => r.status === 200 });
}
