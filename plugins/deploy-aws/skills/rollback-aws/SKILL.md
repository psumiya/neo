---
name: rollback-aws
description: Roll back an AWS deploy and/or kill a feature flag when a heartbeat/SLO signal regresses. Use during an incident or when asked to revert a bad deploy.
---

# rollback-aws

Two independent levers, fastest first.

## 1. Kill the feature flag (seconds, no deploy)
If the bad behavior is behind an AppConfig flag, disable it first — this is the fastest mitigation:
```
aws appconfig update-deployment ...      # or set the flag to off in the AppConfig hosted config
```
Confirm the heartbeat metric recovers before doing anything heavier.

## 2. Roll back the deploy (minutes)
If the regression is not flag-gated, revert to the previously healthy release:
- **CodeDeploy/ECS**: `aws deploy stop-deployment --deployment-id <id> --auto-rollback-enabled`,
  or trigger a new deployment pinned to the last-good task definition / image SHA.
- **Lambda**: shift the alias weight back to the previous version (0% to the new version).

The `reusable-workflows/rollback.yml` automates this when a CloudWatch alarm on the heartbeat metric
fires; this skill is for manual/assisted rollback and for confirming automated rollback succeeded.

## After rollback
1. Confirm the heartbeat metric and SLO alarms are green again.
2. File an incident issue with the deploy id, the metric that regressed, and the suspected commit.
3. Open a follow-up so the agent can fix-forward behind a flag; do not re-deploy the same SHA.

## Hard rules
- Mitigate first (flag off / roll back), diagnose second.
- Never disable the heartbeat alarm to "stop the noise" during an incident.
