# infra-templates

How I deploy and watch my services: Kustomize manifests for Kubernetes, Terraform for AWS (ECR plus a single EC2 instance or ECS Fargate), Prometheus and Grafana for monitoring, and CI that deploys to a kind cluster on every change. A small Go service in [`app/`](app) is the thing being deployed.

[![CI](https://github.com/whoisch4t/infra-templates/actions/workflows/ci.yml/badge.svg)](https://github.com/whoisch4t/infra-templates/actions/workflows/ci.yml)
[![kind](https://github.com/whoisch4t/infra-templates/actions/workflows/kind.yml/badge.svg)](https://github.com/whoisch4t/infra-templates/actions/workflows/kind.yml)
[![Security](https://github.com/whoisch4t/infra-templates/actions/workflows/security.yml/badge.svg)](https://github.com/whoisch4t/infra-templates/actions/workflows/security.yml)

**Stack:** Kubernetes, Kustomize, Terraform (AWS), GitHub Actions, kind, Trivy, Prometheus, Grafana, Go.

```
app/                       demo service: /healthz, /readyz, /metrics, optional /fault
k8s/
  base/                    Deployment, Service, HPA, PDB, NetworkPolicy, ServiceAccount
  components/monitoring/   ServiceMonitor, PrometheusRule (alerts), Grafana dashboard
  overlays/dev|prod|ci/    per-environment replicas, resources, HPA range, image tag
monitoring/                kube-prometheus-stack values + promtool tests for the alerts
terraform/
  bootstrap/               state bucket, GitHub OIDC plan role, budget alert (run once)
  modules/ecr|ec2-app|ecs-fargate/
  envs/demo/               wires the modules; remote state in S3
scripts/smoke-test.sh      what CI runs against the kind cluster
```

## Kubernetes

The base is safe by default; the overlays only change sizes:

|                     | base                                    | dev                     | prod                                   |
| ------------------- | --------------------------------------- | ----------------------- | -------------------------------------- |
| Replicas / HPA      | 2, HPA 2–5 at 70% CPU                   | 1, HPA 1–2              | 3, HPA 3–10                            |
| Resources (req/lim) | 50m/250m CPU, 32/64 Mi                  | same                    | 100m/500m CPU, 64/128 Mi               |
| PodDisruptionBudget | maxUnavailable 1                        | removed (one replica)   | maxUnavailable 1                       |
| Spread              | –                                       | –                       | across nodes and zones                 |
| `/fault` endpoint   | off                                     | on, to test the alert   | off                                    |

All overlays get:

- **Probes.** A startup probe gives the pod up to 30 s to boot. Liveness checks `/healthz`. Readiness checks `/readyz`, which turns 503 on SIGTERM. The app keeps serving for a few seconds after that, so it leaves the Service before the listener closes and rolling updates drop no requests.
- **Rolling updates.** `maxUnavailable: 0`, `maxSurge: 1`, and the last 5 revisions kept for `kubectl rollout undo`.
- **NetworkPolicy, default deny.** Incoming traffic is allowed only from the `monitoring` and `ingress-nginx` namespaces, and from pods labelled `app.kubernetes.io/access: app`. Outgoing traffic is DNS only.
- **Restricted pods.** The namespace enforces the `restricted` Pod Security Standard. Containers run as non-root, with a read-only root filesystem, all capabilities dropped and the RuntimeDefault seccomp profile. No service account token is mounted.
- **Config.** A ConfigMap generator adds a content hash to the name, so a config change rolls the pods.

```bash
kubectl apply -k k8s/overlays/dev
kubectl kustomize k8s/overlays/prod     # see what prod would get
```

The HPA needs metrics-server, which managed clusters usually ship with. Image tags are pinned per overlay. A release is a PR that bumps `newTag` in `k8s/overlays/prod`.

## Monitoring

[kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack) runs Prometheus, Alertmanager and Grafana. Each app brings its own monitoring objects through the `k8s/components/monitoring` component:

- **ServiceMonitor:** Prometheus scrapes `/metrics` every 15 s.
- **Alerts (PrometheusRule):**
  - `AppHighErrorRate` (warning): more than 5% of requests return 5xx over 5 minutes, for 5 minutes.
  - `AppDown` (critical): no pod can be scraped for 2 minutes.
  - Both link to the runbook sections below.
- **Grafana dashboard:** pods up, requests per second, 5xx ratio, running version, latency p50/p95/p99, and memory and CPU per pod. The Grafana sidecar loads it from any namespace.

```bash
kubectl create namespace monitoring
kubectl -n monitoring create secret generic grafana-admin \
  --from-literal=admin-user=admin --from-literal=admin-password="$(openssl rand -base64 24)"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  --version 92.16.1 -n monitoring -f monitoring/values.yaml
kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80
```

Alertmanager sends everything to a null receiver until you add Slack, email or PagerDuty in a private values file. The alert rules have unit tests ([monitoring/tests](monitoring/tests/app-rules.test.yaml)) that CI runs with `promtool`. They check that each alert fires at the right time, stays pending before that, and stays quiet below the threshold or when only one pod is down.

## CI

| Workflow                                              | What it does                                                                                                   |
| ----------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| [ci.yml](.github/workflows/ci.yml)                    | Go tests with `-race`; render every overlay and check it with `kubeconform -strict` (CRDs included); promtool rule tests; shellcheck; `terraform fmt`/`validate`/`tflint`; a guard that fails if any workflow runs `apply`/`destroy` |
| [kind.yml](.github/workflows/kind.yml)                | Build the image, start kind, install kube-prometheus-stack, deploy the dev overlay, run [smoke-test.sh](scripts/smoke-test.sh) |
| [security.yml](.github/workflows/security.yml)        | Trivy on the image (fails on fixable HIGH/CRITICAL), on dependencies and secrets, and on Terraform, the Dockerfile and the rendered overlays. Also runs weekly, since new CVEs appear without code changes |
| [terraform.yml](.github/workflows/terraform.yml)      | `terraform plan` through a read-only OIDC role, with an Infracost estimate. **Plan only, never apply.** Skipped until the repository variables are set |

Dependabot keeps Go modules, the base image, Terraform providers and actions current.

The smoke test checks more than "the pod started":

1. Every endpoint answers from a pod that is allowed in.
2. A pod without the access label is **blocked** by the NetworkPolicy.
3. Prometheus has the app as a healthy target.
4. Requests to `/fault` show up as 500s in Prometheus.
5. Both alert rules are loaded.
6. **Rollback drill:** deploy an image that doesn't exist, confirm the old pod keeps serving, run `kubectl rollout undo`, and confirm the app is healthy again.

Accepted Trivy findings live in [.trivyignore.yaml](.trivyignore.yaml), each with its reason. They are all cost trade-offs: SSE-S3 instead of KMS, and egress on 443 instead of paid VPC endpoints.

## AWS with Terraform

```bash
# 1. Once per account: state bucket, OIDC plan role, budget alert (local state).
terraform -chdir=terraform/bootstrap init
terraform -chdir=terraform/bootstrap apply \
  -var bucket_name=<unique-name> -var github_repository=<owner>/infra-templates -var budget_email=<you@example.com>

# 2. Everything else, with remote state in that bucket.
cd terraform/envs/demo
cp backend.hcl.example backend.hcl && cp terraform.tfvars.example terraform.tfvars   # edit both
terraform init -backend-config=backend.hcl
terraform plan                  # read it, and check the cost section below, before any apply
```

- **Remote state:** S3 with versioning, encryption, a TLS-only policy and blocked public access. Locking uses S3's own lock file (`use_lockfile`), so there's no DynamoDB table.
- **ECR:** immutable tags, scan on push, untagged images expire after a day, and only the last 10 images are kept.
- **`compute = "ec2"` (default):**
  - One `t3.micro` running Amazon Linux 2023, with the container as a systemd service.
  - IMDSv2 only, an encrypted gp3 disk, and access through SSM Session Manager (no SSH keys, no port 22).
  - CPU credits set to `standard`, so bursts throttle instead of billing.
  - A `check` block refuses instance types outside the free tier unless `allow_paid_instance_type = true`.
- **`compute = "fargate"`:**
  - The smallest task (0.25 vCPU, 0.5 GB), optionally on Fargate Spot.
  - The deployment circuit breaker rolls back failed deploys on its own.
  - Logs are kept 7 days and Container Insights is off.
- **Network:** the default VPC with public subnets. A NAT gateway would cost more than everything else here combined.

To enable the plan job, set these repository variables: `AWS_PLAN_ROLE_ARN` (bootstrap output), `TF_STATE_BUCKET` and optionally `AWS_REGION`. For cost estimates, add an `INFRACOST_API_KEY` secret.

## Cost estimate

The figures are monthly (730 hours) on-demand prices in us-east-1. Check the [AWS pricing pages](https://aws.amazon.com/pricing/) or run Infracost on your plan before applying, because prices and free-tier terms change and other regions cost 5–15% more.

AWS has two free-tier models:

- **Accounts opened before 15 July 2025** get the 12-month free tier: 750 h/month of t2/t3.micro, 30 GB of EBS, 750 h of public IPv4 and 500 MB of ECR storage.
- **Newer accounts** are on the Free plan: up to $200 in credits for 6 months, spent on the same list prices below.

| Item                                   | Price                          | Monthly, list price | Legacy free tier |
| -------------------------------------- | ------------------------------ | ------------------: | ---------------: |
| **EC2 option**                         |                                |                     |                  |
| t3.micro                               | $0.0104/h                      | $7.59               | $0               |
| gp3 root disk, 8 GB                    | $0.08/GB-month                 | $0.64               | $0               |
| Public IPv4                            | $0.005/h                       | $3.65               | $0               |
| **EC2 total**                          |                                | **≈ $11.90**        | **≈ $0**         |
| **Fargate option** (0.25 vCPU, 0.5 GB) |                                |                     |                  |
| vCPU, x86                              | $0.04048/vCPU-h                | $7.39               | not covered      |
| Memory                                 | $0.004445/GB-h                 | $1.62               | not covered      |
| Public IPv4                            | $0.005/h                       | $3.65               | $0               |
| **Fargate total**                      |                                | **≈ $12.65**        | **≈ $9.00**      |
| …on ARM64 / on Fargate Spot            | ~20% / up to ~70% less compute | ≈ $10.85 / ≈ $6.35  | ≈ $7.20 / ≈ $2.70 |
| **Shared**                             |                                |                     |                  |
| ECR, ~100 MB of images                 | $0.10/GB-month                 | $0.01               | $0               |
| CloudWatch Logs, < 1 GB                | $0.50/GB ingested              | < $0.50             | $0 (5 GB free)   |
| S3 state + versions                    | KBs                            | < $0.01             | $0               |
| Budget alert (first two budgets)       | free                           | $0                  | $0               |
| Data out, < 100 GB                     | free                           | $0                  | $0               |

Things deliberately left out because they'd dominate the bill:

- NAT gateway: ≈ $32.85/month plus data.
- Application Load Balancer: ≈ $16.43/month plus LCUs.
- EKS control plane: $73/month. The Kubernetes manifests work on any cluster, and kind in CI costs nothing.
- KMS keys: $1/month each.
- Interface VPC endpoints: ≈ $7.30/month each.

**Before any apply:**

1. Run `terraform plan`.
2. Run `infracost breakdown --path .` or read the CI estimate.
3. Make sure the budget alert from bootstrap is in place.
4. When you're done, run `terraform destroy` in `envs/demo`. The bootstrap bucket is protected with `prevent_destroy`.

## Rollback

**Kubernetes (normal path).** Releases are git commits, so a rollback is a revert:

```bash
git revert <release-commit>      # puts the previous image tag back in k8s/overlays/prod
kubectl apply -k k8s/overlays/prod
kubectl -n app-prod rollout status deployment/app
```

**Kubernetes (emergency, seconds).** Roll back first, then make git match. Otherwise the next apply redeploys the bad version.

```bash
kubectl -n app-prod rollout history deployment/app
kubectl -n app-prod rollout undo deployment/app              # or --to-revision=<n>
kubectl -n app-prod rollout status deployment/app
```

`rollout undo` brings back the old pod template, including its hashed ConfigMap name. Apply without `--prune` so old ConfigMaps stay around for this. CI runs this drill on every change.

**ECS Fargate.**

- The deployment circuit breaker rolls back a deploy whose tasks keep failing, without anyone stepping in.
- Manually: `aws ecs update-service --cluster app --service app --task-definition app:<previous-revision>`. Or set `image_tag` back and apply. ECR tags are immutable, so the old tag is still the exact old image.

**EC2.** Set `image_tag` back, then plan and apply. The instance is replaced, which means a few minutes of downtime for this single-instance setup.

**Monitoring.** `helm -n monitoring history monitoring`, then `helm -n monitoring rollback monitoring <revision>`.

**Terraform state.** Every write is a new S3 object version:

```bash
aws s3api list-object-versions --bucket <bucket> --prefix infra-templates/demo/terraform.tfstate
aws s3api copy-object --bucket <bucket> --key infra-templates/demo/terraform.tfstate \
  --copy-source "<bucket>/infra-templates/demo/terraform.tfstate?versionId=<good-version>"
```

## Disaster scenarios

The app is stateless, so recovering means redeploying from git and the registry. RTO is how long recovery takes; RPO is how much data can be lost.

| Scenario                              | How you find out                              | Recovery                                                                                                    | RTO / RPO               |
| ------------------------------------- | --------------------------------------------- | ----------------------------------------------------------------------------------------------------------- | ----------------------- |
| Bad release                           | `AppHighErrorRate`, `AppDown`, failed rollout | [Rollback](#rollback). `maxUnavailable: 0` keeps the old pods serving while new ones fail.                  | minutes / none          |
| A node dies                           | Pods rescheduled, `KubeNodeNotReady`          | Nothing to do. Prod runs 3+ replicas spread over nodes and zones; the PDB limits voluntary evictions.       | seconds / none          |
| The whole cluster is gone             | Everything is down, `Watchdog` stops firing   | New cluster, then the Helm install from [Monitoring](#monitoring), then `kubectl apply -k k8s/overlays/prod`. Prometheus history is lost (7 days); add remote write if that matters. | ~30 min / metrics only |
| AWS region outage                     | AWS Health, nothing reachable                 | Push the image to ECR in another region, `terraform apply -var region=<other>` with a new state key. ECR cross-region replication would cut this but adds cost. | ~1 h / none   |
| State file corrupted or deleted       | `terraform plan` errors or wants to recreate everything | Restore an older S3 version (above). The bucket itself has `prevent_destroy`.                    | minutes / last write    |
| Image deleted from ECR                | Pods or tasks fail with image pull errors     | Rebuild from the git tag (`docker build --build-arg VERSION=<tag> app`) and push. Running pods keep working meanwhile. | ~15 min / none |
| Leaked AWS credentials                | CloudTrail, the budget alert                  | CI has no long-lived keys (OIDC, read-only). For a leaked user key: deactivate it, review CloudTrail, rotate. | – |
| Leaked Grafana password               | –                                             | Recreate the `grafana-admin` secret and restart Grafana.                                                    | minutes                 |
| Unexpected bill                       | Budget alert at 80% actual, or 100% forecasted | Find the item in Cost Explorer, `terraform destroy` in `envs/demo`, then compare with the cost table.       | –                       |

## Running checks locally

```bash
cd app && go test ./...
kubectl kustomize k8s/overlays/prod | kubeconform -strict -summary -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
yq '.spec' k8s/components/monitoring/prometheusrule.yaml > monitoring/tests/rules.yaml
promtool test rules monitoring/tests/app-rules.test.yaml
terraform -chdir=terraform/envs/demo init -backend=false && terraform -chdir=terraform/envs/demo validate
trivy config --ignorefile .trivyignore.yaml .
```

## License

MIT
