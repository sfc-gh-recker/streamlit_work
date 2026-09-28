# Streamlit Development & Management on Snowflake

A reference workflow for developing, governing, and promoting Streamlit in Snowflake (SiS) apps at enterprise scale.

Prepared for the Fanatics DSEA team by Rich Ecker, Snowflake Solutions Engineering.

---

## The problem

Users build Streamlit dashboards that break without the data engineering team knowing, generating support load the team never agreed to. The root cause is not self-service — that is the goal. It is that **there is no defensible line between a dashboard someone threw together and a dashboard the business depends on**, so every app becomes data engineering's problem by default.

## The line: deployment provenance

A Streamlit app either carries evidence of where its code came from, or it does not. That evidence is recorded by the deployment mechanism, not by a human remembering to fill in a field, so it cannot be faked or forgotten.

```sql
DESCRIBE STREAMLIT <db>.<schema>.<app>;
```

There are two governed deployment paths, and they record provenance in different places. This matters — an audit that only checks one will misclassify the other:

| Path | `source_location_uri` | `git_commit_hash` | Evidence |
|---|---|---|---|
| `CREATE STREAMLIT FROM @git_repo/branches/main/` | Git stage path | **populated** | Commit hash on the app object |
| DCM `DEFINE STREAMLIT FROM 'asset://…'` | `asset://<name>` | *empty* | DCM project deployment history |
| Clicked together in Snowsight | internal stage | *empty* | **none** |

An app with neither is ungoverned. That is the promotion gate and the support boundary.

## The pattern: three tiers, one gate

| | Tier 1 Explore | Tier 2 Team | Tier 3 Certified |
|---|---|---|---|
| Where | Personal workspace | Team schema | PROD schema |
| Owner | Individual | Named team role | **Functional role, never a person** |
| Source of truth | Whatever is in the workspace | Feature branch | Immutable Git tag |
| Deployed by | The user | `snow streamlit deploy` | DCM project via CI/CD |
| Provenance | none | present | present |
| In the catalog | no | no | **yes** |
| **DE supports it** | **no** | **no** | **yes** |

See [`brief/streamlit_workflow_brief.md`](brief/streamlit_workflow_brief.md) and [`brief/lifecycle_flow.svg`](brief/lifecycle_flow.svg).

## What the audit found on a real account

| Finding | Count (of 82) |
|---|---|
| No provenance at all | **81 (98.8%)** |
| Legacy `ROOT_LOCATION` source model | **60 (73%)** |
| Admin-owned (viewers inherit admin rights) | 65 |
| Streamlit version not pinned exactly | **81 (100%)** |
| Certified | **2** |

Three of these change how you plan:

- **81 of 82 have no provenance.** When one breaks there is no diff to read and no commit to roll back to.
- **60 of 82 are legacy `ROOT_LOCATION`.** Those apps *cannot* use Git integration or the container runtime. This is a hard technical ceiling, not a process gap — three quarters of the estate must be migrated to the `FROM` source model before a Git workflow applies to them at all. Any plan that says "start using Git" understates the work by that number.
- **82 of 82 have no exact version pin.** Range pins like `streamlit>=1.39.0` silently do not take effect (SNOW-3601653), so apps change behaviour with no code edit.

## Layout

```
.
├── audit/
│   └── streamlit_inventory.sql      Inventory procedure, reporting views, weekly task
├── brief/
│   ├── streamlit_workflow_brief.md  Session one-pager
│   ├── lifecycle_flow.drawio        Editable diagram
│   └── lifecycle_flow.svg           Rendered diagram
├── demo/
│   └── 01_provenance_proof.sql      60-second read-only proof
├── demo_app/                        DCM project: app + data + access as one unit
│   ├── manifest.yml
│   ├── sources/definitions/
│   │   ├── pipeline.sql             Tables and serving view
│   │   ├── access.sql               Functional owner, viewer, developer roles
│   │   └── dashboard.sql            DEFINE STREAMLIT
│   └── streamlit/merch_performance/
│       ├── streamlit_app.py         Reference app (correct session-state patterns)
│       ├── requirements.txt         Exact pins
│       └── utils/
│           ├── config.py            Runtime environment inference
│           └── data.py              Parameterized queries
└── .github/workflows/deploy.yml     PR plan, main deploy, provenance verification
```

## Quick start

```bash
# 1. Inventory your own estate
snow sql -f audit/streamlit_inventory.sql
snow sql -q "CALL GOVERNANCE.APPS.SP_AUDIT_STREAMLIT_APPS()"
snow sql -q "SELECT * FROM GOVERNANCE.APPS.V_STREAMLIT_SPRAWL_SUMMARY"

# 2. See what needs fixing first
snow sql -q "SELECT * FROM GOVERNANCE.APPS.V_STREAMLIT_REMEDIATION_QUEUE LIMIT 20"

# 3. Deploy the reference app
cd demo_app
snow dcm create --target dev
snow dcm plan   --target dev --save-output
snow dcm deploy --target dev
```

## Gotchas this repo encodes

Each of these was hit and verified while building it, not taken from documentation:

| Gotcha | Consequence |
|---|---|
| `GRANT OWNERSHIP ON STREAMLIT` is unsupported in DCM *and* in SQL | Streamlit ownership **cannot be transferred**. The deploying role is the owner permanently, so admin-owned apps must be **recreated**, not re-granted. |
| `SHOW DEPLOYMENTS IN DCM PROJECT` has a `git_commit_hash` column that **never populates** | Not even from a pinned `commits/<sha>/` path. The only Git evidence DCM keeps is `source_file_path`, so deploy from `tags/` or `commits/` — a `branches/` path records a moving pointer and the shipped commit becomes unrecoverable. |
| `CREATE STREAMLIT` and `ADD VERSION` accept **only** `branches/` paths | They reject `tags/` and `commits/` with *Invalid git branch path*, despite the documented `FROM { <snowgit_tag_uri> \| <snowgit_commit_uri> }`. The branch is resolved to a SHA and frozen on the version, so auditability holds — but **tag-pinned releases must go through DCM**. |
| The two mechanisms have **opposite** path requirements | Get it backwards and you either hard-fail (Streamlit) or silently lose auditability (DCM). |
| DCM Jinja variables do not reach Streamlit Python files | Hardcoding a database name ships a PROD app reading DEV data, silently. Use `CURRENT_DATABASE()`. |
| An explicit asset path flattens directories | `utils/config.py` materializes as `config.py` and imports break. Only a `**` glob preserves package structure. |
| A `**` glob sweeps in `__pycache__` | Globs have no negation, so clean bytecode before deploying. |
| `DEFINE STREAMLIT` defaults to the **container** runtime | A shipped `environment.yml` is silently ignored. Use `requirements.txt`, and declare the runtime explicitly. |
| `user_packages` is empty for container-runtime apps | It cannot verify your pins. Report `st.__version__` from inside the app instead. |
| No `ACCOUNT_USAGE.STREAMLITS` view exists | An inventory must loop `SHOW` + `DESCRIBE` into a table. |
| Snowflake regex rejects the `(?i)` inline flag | Use `REGEXP_LIKE(col, pattern, 'i')`. |
| DCM `ATTACH TAG` does not support STREAMLIT | Certification tags must be applied with `ALTER STREAMLIT … SET TAG`, not declaratively. |
| `ALTER STREAMLIT … VERSION … SET ALIAS` is rejected as a syntax error | Documented in the 2025_01 BCR note, not available in 10.34.101. Name the version correctly when adding it. |

## References

- [About Streamlit in Snowflake](https://docs.snowflake.com/en/developer-guide/streamlit/about-streamlit)
- [Owner's rights and Streamlit apps](https://docs.snowflake.com/en/developer-guide/streamlit/object-management/owners-rights)
- [Understanding the different types of Streamlit objects](https://docs.snowflake.com/en/developer-guide/streamlit/migrations-and-upgrades/overview)
- [Privileges required to create and use a Streamlit app](https://docs.snowflake.com/en/developer-guide/streamlit/object-management/privileges)
- [Streamlit in Snowflake in Workspaces](https://docs.snowflake.com/en/developer-guide/streamlit/streamlit-in-workspaces/streamlit-in-workspaces-overview)
- [Supported entities in DCM Projects](https://docs.snowflake.com/en/user-guide/dcm-projects/dcm-projects-supported-entities)
- [Using a Git repository in Snowflake](https://docs.snowflake.com/en/developer-guide/git/git-overview)
