# Configuration reference

`.neo/config.yml` is the one file you edit in a target repo. It is read by the risk classifier
(`plugins/risk-review/scripts/classify.py`) and by the reusable workflows in `psumiya/neo`.
The annotated template lives at
[`templates/target-repo/.neo/config.yml`](../templates/target-repo/.neo/config.yml).

## `app`

| Key | Meaning |
|---|---|
| `name` | App name; also the default ECR repository name for AWS deploys. |
| `build` | Install/build command, e.g. `npm ci`. |
| `test` | Test command. The agent runs this; it must be green before a PR opens. |
| `lint` | Lint/typecheck command. Optional; leave blank to skip. |

## `risk`

Drives GREEN/YELLOW/RED classification of every PR.

| Key | Meaning |
|---|---|
| `max_lines_green` | Maximum added+removed lines for a PR to qualify as GREEN. Default 80. |
| `green_paths` | Glob list. Every changed path must match one for the PR to be GREEN. |
| `blocked_paths` | Glob list. Any changed path matching one makes the PR RED. |

The rules, exactly:

- **GREEN** (auto-merged): total added+removed lines <= `max_lines_green`, **and** every changed
  path matches `green_paths`, **and** no path matches `blocked_paths`.
- **RED** (human review + protected approval, never auto-merged): any changed path matches
  `blocked_paths`.
- **YELLOW** (human review): everything else.

The template's defaults are conservative by design: docs, markdown, feature flags, and
user-facing copy are green; migrations, schema/SQL, auth, billing, payments, infra, Dockerfiles,
workflow files, and the policy file itself are blocked. Widen `green_paths` or raise
`max_lines_green` as your rollback rate stays low.

Two deliberate choices in the default blocklist:

- `.neo/config.yml` and `.neo/deploy/**` are blocked so an agent can't loosen its own policy or
  deploy manifests in a GREEN PR.
- `.neo/` as a whole is **not** blocked: agents are required to add eval cases under
  `.neo/evals/cases/` for every behavioral PR, and that must not force a RED tier.

## `deploy`

`target: none` ships no deploy workflow; you deploy however you like. `target: aws` enables the
reference adapter (`neo-deploy.yml` caller + reusable `deploy.yml`/`rollback.yml`), which reads:

| Key | Meaning |
|---|---|
| `aws.region` | AWS region. |
| `aws.ecr_repository` | ECR repository for the image build. |
| `aws.ecs_cluster` / `aws.ecs_service` | The ECS/Fargate service being deployed. |
| `aws.codedeploy_app` / `aws.codedeploy_group` | CodeDeploy application and deployment group for the blue-green cut-over. |
| `aws.task_def_path` | Default `.neo/deploy/task-definition.json`. |
| `aws.appspec_path` | Default `.neo/deploy/appspec.yaml`. |
| `aws.container_name` | Container to swap in the task definition. Default `app`. |

### `deploy.heartbeat`

The heartbeat is an **outcome** signal (successful requests, completed checkouts), not
CPU/memory. It is watched during the canary bake window and drives promote/rollback; the same
metric's CloudWatch alarm can trigger the standalone rollback workflow later.

| Key | Meaning |
|---|---|
| `namespace` / `metric` | The CloudWatch metric to watch. |
| `min_ratio` | Healthy if canary >= this ratio of baseline during the bake window. Default `0.95`. |

## `evals`

| Key | Meaning |
|---|---|
| `dir` | Where eval cases live. Default `.neo/evals/cases`. |

Behavioral/RAG changes must add a case here; a behavioral PR with none can't be GREEN.

## Workflow inputs

The reusable workflows accept inputs you can override in your `neo.yml` caller:

| Workflow | Input | Default |
|---|---|---|
| `neo-build.yml` | `model` | `claude-sonnet-4-6` |
| `neo-build.yml` | `max_turns` | `40` |
| `ai-review.yml` | `model` | `claude-sonnet-4-6` |
| `ai-review.yml` | `run_evals` | `true` |
| both | `marketplace_url` | `https://github.com/psumiya/neo.git` |

Both also require the `anthropic_api_key` secret, which the stamped `neo.yml` already passes from
the repo's `ANTHROPIC_API_KEY`.
