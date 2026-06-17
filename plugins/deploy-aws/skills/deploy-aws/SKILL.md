---
name: deploy-aws
description: Drive or debug an AWS blue-green deploy (ECS/Fargate or Lambda) with canary and heartbeat watch. Use when a deploy is failing, stuck, or you need to reason about the rollout.
---

# deploy-aws

The reference deploy adapter. Production rollout is run by `reusable-workflows/deploy.yml`; this
skill is the runbook for understanding/operating it and for the adapter contract any new target
implements.

## Adapter contract (every deploy target implements these)
`build` -> `preprod-deploy` -> `smoke` -> `canary` -> `promote` -> `rollback`. Each is a step the
deploy workflow calls. A new target type (static-frontend, ios-mac, browser-extension) is a new
implementation of these six.

## AWS reference flow (matches the Intercom pipeline)
1. **build** — build container image / Lambda bundle, tag with the commit SHA, push to ECR.
2. **preprod-deploy** — deploy the SHA to a pre-prod ECS service / Lambda alias wired to
   prod-like datastores. Run boot test (does it start and pass `/health`?).
3. **smoke** — run smoke tests + Datadog/synthetic checks on critical flows against pre-prod.
   Any failure aborts before prod.
4. **canary** — CodeDeploy blue-green shifts a small slice of prod traffic
   (`CodeDeployDefault.ECSCanary10Percent5Minutes` or a Lambda canary alias) to the new version.
5. **heartbeat watch** — during the canary window, watch the repo's heartbeat metric + SLO alarms
   (see `scripts/heartbeat_check.py`). If the alarm trips, CodeDeploy auto-rolls-back; do not promote.
6. **promote** — if canary is clean, shift 100%. New behavior stays behind an AppConfig flag
   (default-off) so release is decoupled from deploy.

## Feature flags
Ship risky behavior behind an AWS AppConfig flag, default-off. Enabling/disabling is a config push
(<60s), not a deploy. The PR's `## Rollback` section names the flag.

## Debugging a stuck deploy
- `aws deployment get-deployment --deployment-id <id>` for CodeDeploy state.
- ECS: check service events and task stopped-reasons. Lambda: check alias weights + CloudWatch logs.
- If pre-prod boot/smoke failed, the bug is in the build — fix forward, do not force-promote.

## Hard rules
- Never promote past a tripped heartbeat alarm.
- Never deploy a SHA that did not pass pre-prod smoke.
