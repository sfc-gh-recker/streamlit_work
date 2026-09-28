# 03 — Promotion Pipeline

## 1. The unit of promotion is not the app

A Streamlit dashboard is the visible part of something larger: the tables it reads, the view that defines its contract, the roles that decide who sees what, and the warehouse it runs on. Promoting only the Python file is how you get a PROD app pointed at a DEV table, or a dashboard that renders but returns nothing because a grant was never made.

**DCM Projects** make the app, its data, and its access model one deployable unit. That is why the recommended promotion mechanism is DCM rather than `snow streamlit deploy` alone.

```
demo_app/
├── manifest.yml                     targets, assets, templating
├── sources/definitions/
│   ├── pipeline.sql                 DEFINE DATABASE / SCHEMA / TABLE / VIEW
│   ├── access.sql                   DEFINE ROLE + GRANT
│   └── dashboard.sql                DEFINE STREAMLIT
└── streamlit/merch_performance/     the app, imported as an asset
```

One command promotes all of it:

```bash
snow dcm plan   --target prod --save-output
snow dcm deploy --target prod --alias "$(git rev-parse --short HEAD)"
```

## 2. Environment topology

One definition set, three environments, distinguished by a single template variable.

| Environment | Objects | DCM project object | Deployed by |
|---|---|---|---|
| DEV | `FANATICS_MERCH_DEV.*` | `…MERCH_PERFORMANCE_DEV` | Developer, locally |
| TEST | `FANATICS_MERCH_TEST.*` | `…MERCH_PERFORMANCE_TEST` | CI on merge to `develop` |
| PROD | `FANATICS_MERCH.*` | `…MERCH_PERFORMANCE_PROD` | CI on merge to `main`, gated |

**Each environment needs its own DCM project object.** A single project object holds one deployed configuration at a time, so pointing one project at a different configuration *drops the objects from the previous one*. Sharing a project object across environments means deploying PROD deletes DEV.

```yaml
manifest_version: 2
type: DCM_PROJECT
default_target: dev

targets:
  dev:
    account_identifier: MYORG-MYACCOUNT
    project_name: GOVERNANCE.PROJECTS.MERCH_PERFORMANCE_DEV
    project_owner: ACCOUNTADMIN        # demo only; see PROD
    templating_config: DEV
  prod:
    account_identifier: MYORG-MYACCOUNT
    project_name: GOVERNANCE.PROJECTS.MERCH_PERFORMANCE_PROD
    project_owner: APP_DEPLOYER_PROD   # dedicated role, service users only
    templating_config: PROD

templating:
  defaults:
    warehouse: 'MY_WH'
  configurations:
    DEV:  { env_suffix: '_DEV' }
    TEST: { env_suffix: '_TEST' }
    PROD: { env_suffix: '' }           # empty string, not absent
```

`project_owner` for PROD carries more weight than it appears to. Because Streamlit ownership cannot be transferred, **the deploying role permanently becomes the role the app runs as** — so this line decides what every viewer of the production dashboard can reach. See [04](04_rbac_and_ownership.md).

## 3. `DEFINE STREAMLIT`

```sql
DEFINE STREAMLIT FANATICS_MERCH{{ env_suffix }}.SERVE.MERCH_PERFORMANCE
    FROM 'asset://merch_performance/'
    MAIN_FILE = 'streamlit_app.py'
    QUERY_WAREHOUSE = {{ warehouse }}
    COMPUTE_POOL = SYSTEM_COMPUTE_POOL_CPU
    RUNTIME_NAME = 'SYSTEM$ST_CONTAINER_RUNTIME_PY3_11'
    TITLE = 'Merch Performance{{ env_suffix }}'
;
```

Behaviours worth knowing:

- The app is **live immediately** after first deployment. DCM initializes the live version; no manual `ALTER STREAMLIT` needed.
- Removing the `DEFINE` statement **drops the app** on the next deployment. Retirement is a reviewed code change, which is the correct lifecycle.
- `FROM` accepts **only** an `asset://` URI in Public Preview. A relative path fails at compile time.
- **Declare `COMPUTE_POOL` and `RUNTIME_NAME` explicitly.** Omitting them still yields the *container* runtime, which silently invalidates a warehouse-runtime `environment.yml`. See [06](06_tooling_and_runtimes.md).

## 4. Assets: the trap that deploys cleanly and fails at runtime

Asset files are declared in `manifest.yml` and referenced by name. The rule that governs layout: **the literal directory prefix before the first wildcard is stripped.**

Measured behaviour for an app with a `utils/` package:

| Manifest entry | `utils/config.py` materializes as | Result |
|---|---|---|
| `'streamlit/merch_performance/utils/config.py'` | `config.py` | **imports break** |
| `'streamlit/merch_performance/utils/*.py'` | `config.py` | **imports break** |
| `'streamlit/merch_performance/**/*'` | `utils/config.py` | correct |

So any app with a Python subpackage **requires** the `**` form. An explicit file list flattens the tree, the app deploys without error, and it fails when it starts.

```yaml
assets:
  merch_performance:
    path: 'streamlit/merch_performance/**/*'
```

Always verify after planning:

```bash
snow dcm plan --target dev --save-output
find out/rendered/assets -type f
```

**The cost of `**`:** it sweeps in whatever is on disk. A local `python -m py_compile` creates `__pycache__/*.pyc` and the glob deploys them. DCM silently excludes dotfiles and dot-directories, but `__pycache__` is neither, so nothing warns you. Globs support only `*` and `**` — there is no negation — so the manifest cannot exclude it. Handle it outside the manifest:

```bash
export PYTHONDONTWRITEBYTECODE=1
find . -name '__pycache__' -type d -prune -exec rm -rf {} +
```

Limits: 50 MB per file, 5,000 files per run, 512 MB total.

## 5. The limitation that most affects app design

**DCM Jinja variables do not reach Streamlit Python files.** You can template the `DEFINE STREAMLIT` statement; you cannot template the app source.

The tempting shortcut is fatal:

```python
# WRONG — deploys happily to PROD, silently reads DEV data
DATABASE = "FANATICS_MERCH_DEV"
```

Nothing errors. The dashboard renders. The numbers are just wrong, which is worse than a failure.

Ask Snowflake at runtime instead. Because the Streamlit object lives inside its environment's database, the app's current database *is* its environment:

```python
def resolve_environment(conn):
    database = conn.query("SELECT CURRENT_DATABASE() AS DB", ttl=3600)["DB"].iloc[0]
    match = re.search(r"_(DEV|TEST|STAGING|QA)$", database or "", re.IGNORECASE)
    env_label = match.group(1).upper() if match else "PROD"
    return {
        "database": database,
        "env_label": env_label,
        "is_prod": env_label == "PROD",
        "serve_view": f"{database}.SERVE.V_MERCH_PERFORMANCE",
    }
```

Render a visible badge in non-production. It costs nothing and prevents a DEV screenshot reaching an exec deck.

## 6. Plan before deploy

`PLAN` renders Jinja, diffs against current state, converts to DDL, sorts by dependency, and compiles — without executing anything. It requires the same OWNERSHIP privilege as `DEPLOY`, so it surfaces privilege errors too.

```bash
snow dcm plan --target prod --save-output
```

What `PLAN` does **not** do:

- It does not test whether the app *runs*. It only validates that the object can be created.
- It does not guarantee deployment success.
- `PLAN DELTA` is faster but only evaluates changed definitions, so it misses drift caused outside DCM. Run a full `PLAN` before deploying.

Review the plan for unexpected `DROP` entries. A removed `DEFINE` is interpreted as intent to delete.

## 7. Rollback

Two independent mechanisms:

**Streamlit versions.** Each deployment creates `VERSION$N`.

```sql
SHOW VERSIONS IN STREAMLIT FANATICS_MERCH.SERVE.MERCH_PERFORMANCE;
```

**Git revert plus redeploy** — the preferred route, because it keeps the repository as the source of truth and leaves an auditable trail:

```bash
git revert <bad-commit>
git push
# CI redeploys; the deployed object and the repository agree again
```

Rolling the object back without reverting the repository leaves them divergent, and the next deployment silently reapplies the bad change.

DCM deployment history gives the audit trail:

```sql
SHOW DEPLOYMENTS IN DCM PROJECT GOVERNANCE.PROJECTS.MERCH_PERFORMANCE_PROD;
```

The `alias` is worth setting to the commit SHA — it is effectively the commit message for the deployment. Note the deployment row also has its own `git_commit_hash` column, populated when the project itself is deployed *from* a Snowflake Git repository stage.

## 8. CI/CD

Two corrections to patterns commonly seen in earlier guidance:

**Authentication.** Use key-pair or OIDC workload identity federation, not a stored password. Snowflake's CI/CD guidance states password authentication is supported for legacy workflows but is not recommended for production.

**Never bare `--replace`.** `snow streamlit deploy --replace` performs a create-or-replace that **can drop the grants** on the app — silently revoking business users' access to a production dashboard. DCM reconciles the object and keeps grants declared in `access.sql` as part of the same managed unit.

Pipeline shape:

| Trigger | Action | Gate |
|---|---|---|
| PR opened | `snow dcm plan`, post changeset as PR comment | CI must pass |
| Merge to `develop` | `snow dcm deploy --target test` | Review was the gate |
| Merge to `main` | `snow dcm deploy --target prod` | GitHub Environment required reviewers |
| Post-deploy | Verify provenance, refresh inventory | Fail if provenance absent |

The provenance check keeps the catalog honest — if the deployed object cannot prove its origin, it must not be marked certified:

```bash
snow sql -q "SHOW DEPLOYMENTS IN DCM PROJECT GOVERNANCE.PROJECTS.MERCH_PERFORMANCE_PROD" \
  --format json > deployments.json
# fail the build if the app is neither DCM-managed nor Git-sourced
snow sql -q "CALL GOVERNANCE.APPS.SP_AUDIT_STREAMLIT_APPS()"
```

Put required reviewers on the GitHub **Environment**, not in workflow logic. Environment protection cannot be bypassed by editing the workflow file in the same PR.

## 9. What DCM will not do

| Gap | Workaround |
|---|---|
| `GRANT OWNERSHIP ON STREAMLIT` unsupported | None. The deploying role is the owner. Set `project_owner` correctly from the start. |
| `ATTACH TAG` does not support STREAMLIT | Apply certification tags with `ALTER STREAMLIT … SET TAG` as a post-deploy step. |
| Jinja does not reach app source | `CURRENT_DATABASE()` at runtime. |
| `PLAN` does not test that the app runs | Smoke-test the URL; check `snow streamlit logs`. |
| Row access and masking policy *attachment* not yet supported | Attach outside DCM; DCM will not revoke them on redeploy. |

---

Previous: [02 — Git Strategy](02_git_strategy.md) · Next: [04 — RBAC and Ownership](04_rbac_and_ownership.md)
