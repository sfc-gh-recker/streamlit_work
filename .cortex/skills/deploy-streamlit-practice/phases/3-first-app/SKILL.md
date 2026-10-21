---
name: deploy-first-governed-app
description: "Deploy the first Streamlit app with real Git provenance via a DCM project, owned by a functional role so it can be certified."
parent_skill: deploy-streamlit-practice
---

# Phase 3 — First governed app

**Rationale:** `streamlit_strategy_v1/01_dev_workflow_overview.md`,
`03_promotion_pipeline.md`; `00_getting_started.md` step 6.
Worked example: `demo_app/`. Live round trip: `demo/02_git_roundtrip.sql`.

The goal is not an app. It is one app whose provenance can be proved, owned by a
role that is not an admin — the template every later app is copied from. Get
this one right and the practice propagates; get it wrong and so does the error.

## Workflow

### Step 1: Duplicate pre-flight

**⚠️ MANDATORY GATE — do not skip, even for the reference app.**

**Load** `check-duplicate-app/SKILL.md` and complete it. Return here with
either clearance or a recorded decision.

This is the gate that keeps the estate from re-sprawling after the rollout, and
running it on the very first app is what establishes it as routine rather than
bureaucratic.

### Step 2: Confirm the ownership decision

Ask which role will deploy, and make the consequence explicit: **that role owns
the app permanently.** If the answer is an admin role, say plainly that the app
will not be certifiable and will have to be recreated later.

`04_rbac_and_ownership.md` prescribes splitting DCM into two projects — infra
under a broad DDL role, app under the functional owner role — because the app
project's deploying role becomes the app owner. The reference implementation in
this repo does not do that: it proves the pattern with a single
`CREATE STREAMLIT` under the functional role, and its DCM project still deploys
as admin. If the user wants the prescribed shape, build two projects.

### Step 3: Scaffold in the repo

Copy `demo_app/` as the shape, or hand off to
`developing-with-streamlit-in-snowflake` to author the app itself and return
here to deploy it.

Two things the app code must get right:

- Resolve the database with `CURRENT_DATABASE()`. DCM Jinja variables **do not
  reach Streamlit Python files**, so a templated database name ships a prod app
  silently reading dev data.
- Pin dependencies exactly. Range pins silently do not apply on warehouse
  runtime.

### Step 4: Commit, push, fetch

Provenance starts at the commit, so this ordering is load-bearing:

```bash
git add -A && git commit -m "<message>" && git push
git rev-parse HEAD          # read the real SHA; never abbreviate or reconstruct it
```

```sql
ALTER GIT REPOSITORY <repo> FETCH;
```

Read the SHA rather than deriving it from a short hash. A fabricated remainder
fails with `The specified commit ... cannot be found`, which reads like a Git
integration problem and is not.

### Step 5: Plan, then deploy from the commit path

```bash
snow dcm create --target dev -c <CONNECTION>          # first time only
snow dcm plan --from demo_app --target dev -c <CONNECTION>
```

**⚠️ Approval gate.** Present the plan diff and wait. Then:

```sql
EXECUTE DCM PROJECT <project> DEPLOY AS "<unique-alias>"
    FROM '@<repo>/commits/<full-sha>/demo_app/';
```

Three traps live in that one statement:

- **`commits/<sha>/`, not `branches/<br>/`.** DCM records no commit hash
  anywhere except the literal `source_file_path` string, so a branch path leaves
  a moving pointer and the deployment becomes unauditable. This is the opposite
  of the `CREATE STREAMLIT` rule — see the mechanism inversion in
  `references/gotchas.md`.
- **The alias must be unique, and a failed deploy still consumes its alias.**
  Retrying the same one gives `already exists with alias`.
- **Declare the runtime explicitly.** Both `DEFINE STREAMLIT` and
  `snow streamlit deploy` default to container.

### Step 6: Load data

DCM has no `DEFINE` for table contents, so an app that deploys clean renders an
empty dashboard unless a hook runs:

```bash
snow sql -f demo_app/hooks/seed_data.sql --enable-templating JINJA \
  -c <CONNECTION> --variable "env_suffix=_DEV"
```

Pass the suffix **unquoted** — `snow sql --variable` does not strip quotes.

### Step 7: Prove the provenance

This is the phase's actual deliverable. Do not record it complete on a
successful deploy.

```sql
SHOW VERSIONS IN STREAMLIT <db>.<schema>.<app>;
SHOW DEPLOYMENTS IN DCM PROJECT <project>;
SHOW GRANTS ON STREAMLIT <db>.<schema>.<app>;   -- confirm OWNERSHIP role
```

`SHOW VERSIONS` is the best provenance artifact in the product: a per-version
ledger with `source_location_uri` and `git_commit_hash`. Expect
`git_commit_hash` to be **empty** on the DCM path — that is not a failure. The
recoverable evidence is the SHA inside `source_file_path`:

```sql
REGEXP_SUBSTR(source_file_path, '/commits/([0-9a-f]{40})/', 1, 1, 'e', 1)
```

Confirm `OWNERSHIP` is the functional role, not an admin. If it is not, stop:
the app cannot be certified and must be recreated.

**⚠️ Stop and present.** Report the app, its owner, the commit it was deployed
from, and how that commit is recoverable.

## Output

One deployed app with recoverable Git provenance, owned by a functional role,
with data in it. Recorded in `state.json`.

## Next

**Continue** to `phases/4-govern/SKILL.md`.
