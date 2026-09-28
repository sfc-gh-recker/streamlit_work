# 02 — Git Strategy

## 1. Why Git is the system of record

Git is not a compliance checkbox here. It is the mechanism that produces the provenance the whole governance model depends on. Without a repository there is no commit hash, no diff, no rollback target, and no review — and therefore no defensible basis for the platform team to support an app.

It is also the thing analysts actually wanted. Custom SQL in reviewable files, with history, is why teams move off BI tools that hide the query.

## 2. Prerequisite: the source model

**Check this before promising anyone a Git workflow.** Streamlit apps come in two source models and only one of them can use Git at all.

| | `FROM` (current) | `ROOT_LOCATION` (legacy) |
|---|---|---|
| Git integration | yes | **no** |
| Container runtime | yes | **no** |
| Multi-file editing in Snowsight | yes | **no** |
| Source storage | Embedded versioned stage inside the object | An external internal stage it must keep reading |

Diagnostic — the column list differs, so this is unambiguous:

```sql
DESCRIBE STREAMLIT <db>.<schema>.<app>;
```

- returns `root_location` → **legacy**, 13 columns, cannot use Git
- returns `live_version_location_uri` → **current**, 25 columns

Measured on the audited account: **60 of 81 apps (74%) are legacy.** Three quarters of the estate cannot adopt a Git workflow until it is migrated. A rollout plan that omits this understates the work by that proportion, and the gap will surface as "why doesn't this work for my app" in week one.

Find yours:

```sql
SELECT FULL_NAME, OWNER_ROLE, ROOT_LOCATION, AGE_DAYS
FROM GOVERNANCE.APPS.V_STREAMLIT_INVENTORY_LATEST
WHERE IS_LEGACY_SOURCE
ORDER BY AGE_DAYS DESC;
```

Migration means recreating the app with `FROM`. Since ownership also cannot be transferred (see [04](04_rbac_and_ownership.md)), migration and re-owning are the same operation — do them together rather than twice.

## 3. Repository structure

A monorepo per domain, with each deployable app as a DCM project subfolder. This mirrors the AI platform layout and the documented DCM multi-project pattern.

```
streamlit_work/
├── README.md
├── audit/
│   └── streamlit_inventory.sql
├── brief/
├── streamlit_strategy_v1/
├── catalog/
├── demo_app/                        one DCM project
│   ├── manifest.yml
│   ├── sources/definitions/
│   │   ├── pipeline.sql             tables, views
│   │   ├── access.sql               roles, grants
│   │   └── dashboard.sql            DEFINE STREAMLIT
│   └── streamlit/merch_performance/
│       ├── streamlit_app.py
│       ├── requirements.txt
│       └── utils/
└── .github/workflows/deploy.yml
```

Two structural rules worth stating because both are easy to get wrong:

- **`.github/workflows/` must be at the repository root.** GitHub Actions does not discover workflows in subdirectories. If each app folder has its own `.github/`, none of them run.
- **Each DCM project needs its own non-overlapping folder** with its own `manifest.yml` and `sources/definitions/`. Run a specific one with `snow dcm plan --from ./demo_app/`.

## 4. Connecting Snowflake to Git

Snowflake clones the repository into a repository stage. Files can then be referenced by `CREATE STREAMLIT`, `EXECUTE IMMEDIATE FROM`, procedures, and notebooks.

### Public repository

No credentials at all:

```sql
CREATE OR REPLACE API INTEGRATION GIT_API_MY_ORG
  API_PROVIDER = git_https_api
  API_ALLOWED_PREFIXES = ('https://github.com/my-org')
  ENABLED = TRUE;

CREATE OR REPLACE GIT REPOSITORY MY_DB.MY_SCHEMA.MY_REPO
  API_INTEGRATION = GIT_API_MY_ORG
  ORIGIN = 'https://github.com/my-org/my-repo';

ALTER GIT REPOSITORY MY_DB.MY_SCHEMA.MY_REPO FETCH;
```

### Private repository

Adds a secret holding a **read-only** token. Snowflake only ever fetches; it never pushes, so do not grant write scope.

```sql
CREATE OR REPLACE SECRET MY_DB.MY_SCHEMA.GIT_PAT
  TYPE = PASSWORD
  USERNAME = 'my-github-user'
  PASSWORD = '<fine-grained PAT, Contents: Read>';

CREATE OR REPLACE API INTEGRATION GIT_API_MY_ORG
  API_PROVIDER = git_https_api
  API_ALLOWED_PREFIXES = ('https://github.com/my-org')
  ALLOWED_AUTHENTICATION_SECRETS = (MY_DB.MY_SCHEMA.GIT_PAT)
  ENABLED = TRUE;

CREATE OR REPLACE GIT REPOSITORY MY_DB.MY_SCHEMA.MY_REPO
  API_INTEGRATION = GIT_API_MY_ORG
  GIT_CREDENTIALS = MY_DB.MY_SCHEMA.GIT_PAT
  ORIGIN = 'https://github.com/my-org/my-repo';
```

**SSO gotcha.** If the repository is in an organization with SAML SSO enforced, a *classic* PAT must be explicitly authorized for that organization (Configure SSO → Authorize) or the fetch fails with an opaque not-found error indistinguishable from a wrong URL. Fine-grained tokens scoped to the repository avoid this.

`FETCH` is not automatic. Re-fetch before deploying from a branch:

```sql
ALTER GIT REPOSITORY MY_DB.MY_SCHEMA.MY_REPO FETCH;
SHOW GIT BRANCHES IN MY_DB.MY_SCHEMA.MY_REPO;
```

### Deploying an app directly from Git

This is the path that puts the commit hash on the object:

```sql
CREATE OR REPLACE STREAMLIT MY_DB.SERVE.MY_APP
  FROM @MY_DB.MY_SCHEMA.MY_REPO/branches/main/apps/my_app/
  MAIN_FILE = 'streamlit_app.py'
  QUERY_WAREHOUSE = MY_WH;

DESCRIBE STREAMLIT MY_DB.SERVE.MY_APP;   -- git_commit_hash now populated
```

Deploy production from a **tag**, not a branch. A branch moves; a tag is the immutable thing you can roll back to.

## 5. Branching

Trunk-based with short-lived feature branches.

| Branch | Purpose | Deploys to |
|---|---|---|
| `main` | Production-ready. Protected. | PROD, on merge, with approval |
| `develop` | Integration | TEST, on merge |
| `feature/{team}/{ticket}-{desc}` | Individual change, under 5 days | DEV, on push |
| `hotfix/{desc}` | Emergency fix | PROD, expedited |

```
feature/analytics/DATA-1234  ──PR──▶  develop  ──PR──▶  main
                                         │                 │
                                    TEST deploy       PROD deploy
```

Protect `main` and `develop`: require review, require passing CI, require linear history, and forbid force pushes.

## 6. CODEOWNERS

Beyond approval authority, CODEOWNERS gives passive cross-team visibility — teams see what other teams are shipping without anyone having to broadcast it.

```bash
# Platform team reviews anything not covered more specifically
*                                   @org/platform-team

# Each team owns its app folders
/demo_app/                          @org/analytics-team @org/platform-team
/apps/finance/                      @org/finance-analytics @org/platform-team

# Governance tooling is platform-owned
/audit/                             @org/platform-team
/catalog/                           @org/platform-team
/.github/                           @org/platform-team

# Co-owned so every team reviews catalog changes
/catalog/registry.sql               @org/platform-team @org/all-teams
```

## 7. Pull request checks

| Check | Blocks merge |
|---|---|
| `ruff` / `mypy` on app code | yes |
| App imports cleanly | yes |
| `snow dcm plan` renders and compiles | yes |
| Plan contains no unexpected `DROP` | yes |
| Asset layout correct (`find out/rendered/assets`) | yes |
| Exact version pins present | yes |
| Registry entry updated for new apps | warning |

The asset-layout check earns its place. A wrong glob deploys successfully and fails only at runtime — see [03](03_promotion_pipeline.md).

### PR template extract

```markdown
## Asset type
- [ ] New Streamlit app   - [ ] Change to existing app   - [ ] Retirement

## Tier
- [ ] Tier 1 Explore   - [ ] Tier 2 Team   - [ ] Tier 3 Certified

## Required for Tier 3
- [ ] `snow dcm plan` output attached, no unexpected DROP
- [ ] Source model is `FROM`, not `ROOT_LOCATION`
- [ ] Exact version pins in requirements.txt / environment.yml
- [ ] Owner is a functional role, not an individual or an admin role
- [ ] App infers environment via CURRENT_DATABASE(), no hardcoded database
- [ ] Queries parameterized, no f-string SQL
- [ ] Registry entry added with business owner and support group
- [ ] Retirement or review date set
```

## 8. Secrets

Never commit credentials. A deployed app under owner's rights needs none — Snowflake authenticates it automatically.

```gitignore
.streamlit/secrets.toml
**/.streamlit/secrets.toml
out/
__pycache__/
```

`.streamlit/secrets.toml` exists only for local development. For CI, use key-pair authentication or OIDC workload identity federation; Snowflake's CI/CD guidance is explicit that password authentication is not recommended for production.

---

Previous: [01 — Development Workflow Overview](01_dev_workflow_overview.md) · Next: [03 — Promotion Pipeline](03_promotion_pipeline.md)
