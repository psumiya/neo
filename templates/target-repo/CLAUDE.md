# <APP NAME>

> Per-repo contract for the autonomous coding harness. Fill in every `<...>`.

## What this app is
<One paragraph: what it does, the stack, the deploy target (AWS web/backend | static frontend |
iOS/Mac | browser extension | Python/RAG backend).>

## Build / test / run
- Install: `<cmd>`
- Test: `<cmd>`            # the agent runs this; must be green before a PR opens
- Lint/typecheck: `<cmd>`
- Run locally: `<cmd>`

## Conventions
<Naming, structure, patterns to follow and to avoid. Keep concise and factual — this file is
fact-checked weekly by the maintenance workflow.>

## Deploy target
- Type: `aws-web-backend`
- Service: ECS cluster `<cluster>`, service `<svc>`, CodeDeploy app `<app>` / group `<dg>`
- Region: `<region>`

## Heartbeat metric (drives canary promote + rollback)
- CloudWatch namespace: `<MyApp>`
- Metric: `<SuccessfulRequests>`  (an OUTCOME signal, not CPU/memory)
- Healthy if canary >= `<0.95>` x baseline during the bake window
- Rollback bridge: CloudWatch alarm on this metric -> SNS -> repository_dispatch
  `rollback-requested` (see `.github/workflows/rollback.yml`)

## Feature flags
- Provider: AWS AppConfig, application `<...>`, environment `<...>`
- New behavior ships behind a flag, **default-off**. The PR's Rollback section names the flag.

## Risk policy
See `.agent/risk-policy.yml`. GREEN PRs auto-merge with no human review; YELLOW/RED wait for the
repo owner. Touching `<auth/billing/schema/infra paths>` is always RED.

## Evals
Behavioral/RAG changes must add a case under `evals/cases/`. Run: `python3 -m evals` or the harness
runner. A behavioral PR with no eval is not eligible for GREEN.
