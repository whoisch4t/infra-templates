#!/usr/bin/env bash
# Smoke test for the app in a kind cluster (see .github/workflows/kind.yml).
# Assumes: kube-prometheus-stack installed as release "monitoring" in namespace "monitoring",
# and k8s/overlays/ci applied to namespace app-dev.
set -euo pipefail

NS=app-dev
PROM_SVC=monitoring-kube-prometheus-prometheus

step() { printf '\n==> %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# Runs curl in a short-lived pod that passes the "restricted" Pod Security Standard.
# $1: pod name, $2: extra labels (JSON object), rest: curl arguments.
curl_pod() {
  local name=$1 labels=$2
  shift 2
  kubectl -n "$NS" delete pod "$name" --ignore-not-found --wait=true >/dev/null
  kubectl -n "$NS" run "$name" --image=curlimages/curl:8.17.0 --restart=Never --quiet \
    --overrides="$(cat <<JSON
{
  "metadata": {"labels": $labels},
  "spec": {
    "securityContext": {"runAsNonRoot": true, "runAsUser": 100, "seccompProfile": {"type": "RuntimeDefault"}},
    "containers": [{
      "name": "$name",
      "image": "curlimages/curl:8.17.0",
      "args": $(printf '%s\n' "$@" | jq -R . | jq -sc .),
      "securityContext": {"allowPrivilegeEscalation": false, "capabilities": {"drop": ["ALL"]}}
    }]
  }
}
JSON
)" >/dev/null
  local phase=""
  for _ in $(seq 1 90); do
    phase=$(kubectl -n "$NS" get pod "$name" -o jsonpath='{.status.phase}')
    [[ $phase == Succeeded || $phase == Failed ]] && break
    sleep 1
  done
  kubectl -n "$NS" logs "$name" || true
  [ "$phase" = Succeeded ]
}

prom_query() {
  curl -fsS --get "http://localhost:9090/api/v1/query" --data-urlencode "query=$1" | jq -r '.data.result[0].value[1] // empty'
}

step "Rollout"
kubectl -n "$NS" rollout status deployment/app --timeout=120s

step "Allowed client can reach every endpoint"
allowed='{"app.kubernetes.io/access": "app"}'
curl_pod curl-allowed "$allowed" -fsS --max-time 5 http://app/ || fail "GET / from an allowed pod"
curl_pod curl-allowed "$allowed" -fsS --max-time 5 http://app/healthz || fail "GET /healthz"
curl_pod curl-allowed "$allowed" -fsS --max-time 5 http://app/readyz || fail "GET /readyz"
curl_pod curl-allowed "$allowed" -fsS --max-time 5 -o /dev/null http://app/metrics || fail "GET /metrics"

step "NetworkPolicy blocks a pod without the access label"
if curl_pod curl-denied '{}' -fsS --max-time 5 http://app/healthz; then
  fail "a pod without app.kubernetes.io/access=app reached the app"
fi
echo "blocked, as expected"

step "Generate some 500s through the fault endpoint (dev only)"
curl_pod curl-allowed "$allowed" -s --max-time 5 -o /dev/null -w '%{http_code}\n' \
  http://app/fault http://app/fault http://app/fault || true

step "Prometheus scrapes the app and loaded the alert rules"
kubectl -n monitoring port-forward "svc/$PROM_SVC" 9090:9090 >/dev/null 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null || true' EXIT

for i in $(seq 1 40); do
  up=$(prom_query "sum(up{job=\"app\", namespace=\"$NS\"})" 2>/dev/null || true)
  [ "${up:-0}" != 0 ] && break
  sleep 5
done
[ "${up:-0}" != 0 ] || fail "Prometheus has no healthy app target"
echo "app targets up: $up"

for i in $(seq 1 24); do
  errors=$(prom_query "sum(http_requests_total{job=\"app\", namespace=\"$NS\", code=\"500\"})" 2>/dev/null || true)
  [ -n "$errors" ] && [ "${errors%.*}" -ge 1 ] && break
  sleep 5
done
[ -n "${errors:-}" ] || fail "500s from /fault never showed up in Prometheus"
echo "500s recorded by Prometheus: $errors"

rules=$(curl -fsS http://localhost:9090/api/v1/rules | jq -r '[.data.groups[].rules[].name] | join(",")')
for alert in AppHighErrorRate AppDown; do
  [[ ",$rules," == *",$alert,"* ]] || fail "alert $alert not loaded"
done
echo "alert rules loaded: AppHighErrorRate, AppDown"

step "Rollback drill: a broken image doesn't take the app down, and undo restores it"
kubectl -n "$NS" set image deployment/app app=app:does-not-exist
if kubectl -n "$NS" rollout status deployment/app --timeout=30s; then
  fail "rollout with a missing image reported success"
fi
# maxUnavailable: 0 keeps the old pod serving while the new one can't start.
curl_pod curl-allowed "$allowed" -fsS --max-time 5 http://app/healthz || fail "app went down during a bad rollout"
kubectl -n "$NS" rollout undo deployment/app
kubectl -n "$NS" rollout status deployment/app --timeout=120s
curl_pod curl-allowed "$allowed" -fsS --max-time 5 http://app/ || fail "app not serving after rollback"

printf '\nAll smoke tests passed.\n'
