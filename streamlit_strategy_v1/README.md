# Streamlit Development & Management Strategy

## Overview

This documentation set defines how Streamlit apps are developed, governed, promoted, and retired on Snowflake. It is the Streamlit counterpart to the AI Strategy set, and follows the same structure: numbered documents, explicit privilege matrices, runnable DDL, and stated limitations.

Every limitation recorded here was verified empirically against a live Snowflake account in September 2026, not taken from documentation. Where a documented capability turned out not to work as expected, that is called out with what actually happened.

---

## Documents

| # | Document | Covers |
|---|---|---|
| 1 | [Development Workflow Overview](01_dev_workflow_overview.md) | The problem, the provenance gate, the three-tier model, lifecycle |
| 2 | [Git Strategy](02_git_strategy.md) | Git repositories, provenance, branching, CODEOWNERS, custom SQL |
| 3 | [Promotion Pipeline](03_promotion_pipeline.md) | DCM Projects, `DEFINE STREAMLIT`, DEV/TEST/PROD, CI/CD, rollback |
| 4 | [RBAC and Ownership](04_rbac_and_ownership.md) | Owner's rights, functional roles, the self-service grant set |
| 5 | [App Governance and Registry](05_app_governance_registry.md) | Sanctioned vs side project, registry, certification, support boundary |
| 6 | [Tooling and Runtimes](06_tooling_and_runtimes.md) | Workspaces, CLI, runtime choice, dependency pinning, observability |

---

## The one-sentence version

> Develop in a workspace, keep source in Git, promote through DCM Projects under a dedicated deployer role, and support only the apps that can prove where their code came from.

---

## The governance signal

A Streamlit app either carries evidence of its origin or it does not, and that evidence is written by the deployment mechanism rather than by a person remembering to record it.

```sql
DESCRIBE STREAMLIT <db>.<schema>.<app>;
```

| Path | `git_commit_hash` | Evidence of origin |
|---|---|---|
| `CREATE STREAMLIT FROM @git_repo/branches/main/` | populated | Commit hash on the app object |
| DCM `DEFINE STREAMLIT FROM 'asset://…'` | empty | DCM project deployment history |
| Built in Snowsight | empty | none |

Both governed paths are acceptable. An app with neither is a side project, and that is the line where platform support stops.

---

## Verified limitations

These shape the design. Each cost a debugging cycle to find.

| Limitation | Design consequence |
|---|---|
| `GRANT OWNERSHIP ON STREAMLIT` unsupported in DCM **and** in SQL | Ownership cannot be transferred. The deploying role owns the app permanently. Admin-owned apps must be **recreated**, not re-granted. See [04](04_rbac_and_ownership.md). |
| DCM Jinja variables do not reach Streamlit Python files | The app must infer its environment at runtime via `CURRENT_DATABASE()`. Templating a database name ships a PROD app reading DEV data, silently. See [03](03_promotion_pipeline.md). |
| Legacy `ROOT_LOCATION` apps cannot use Git integration or the container runtime | 60 of 81 apps audited are legacy. Migration to `FROM` is a **prerequisite**, not a detail. See [02](02_git_strategy.md). |
| An explicit asset path flattens directories | `utils/config.py` materializes as `config.py` and imports break. Only a `**` glob preserves package structure. See [03](03_promotion_pipeline.md). |
| `DEFINE STREAMLIT` defaults to the container runtime | A shipped `environment.yml` is silently ignored. See [06](06_tooling_and_runtimes.md). |
| `user_packages` is empty for container-runtime apps | It cannot verify pins. Report `st.__version__` from inside the app. See [06](06_tooling_and_runtimes.md). |
| No `ACCOUNT_USAGE.STREAMLITS` view exists | An inventory must loop `SHOW` + `DESCRIBE` into a table. See [05](05_app_governance_registry.md). |
| DCM `ATTACH TAG` does not support STREAMLIT | Certification tags need `ALTER STREAMLIT … SET TAG`; the registry table is the declarative record. See [05](05_app_governance_registry.md). |

---

## Baseline from a real account

Measured across 81 Streamlit apps:

| Finding | Count | Share |
|---|---|---|
| No provenance at all | 79 | 97.5% |
| Legacy `ROOT_LOCATION` source model | 60 | 74% |
| Admin-owned | 65 | 80% |
| Never named (Snowsight auto-name) | 58 | 72% |
| Undocumented | 73 | 90% |
| Streamlit version not pinned exactly | 81 | 100% |
| Over a year old | 68 | 84% |
| Certified | 2 | 2.5% |

Reproduce on your own account with [`audit/streamlit_inventory.sql`](../audit/streamlit_inventory.sql).

---

## Related resources

- [About Streamlit in Snowflake](https://docs.snowflake.com/en/developer-guide/streamlit/about-streamlit)
- [Owner's rights and Streamlit apps](https://docs.snowflake.com/en/developer-guide/streamlit/object-management/owners-rights)
- [Understanding the different types of Streamlit objects](https://docs.snowflake.com/en/developer-guide/streamlit/migrations-and-upgrades/overview)
- [Privileges required to create and use a Streamlit app](https://docs.snowflake.com/en/developer-guide/streamlit/object-management/privileges)
- [Streamlit in Snowflake in Workspaces](https://docs.snowflake.com/en/developer-guide/streamlit/streamlit-in-workspaces/streamlit-in-workspaces-overview)
- [Supported entities in DCM Projects](https://docs.snowflake.com/en/user-guide/dcm-projects/dcm-projects-supported-entities)
- [Using a Git repository in Snowflake](https://docs.snowflake.com/en/developer-guide/git/git-overview)
- [Integrating CI/CD with Snowflake CLI](https://docs.snowflake.com/en/developer-guide/snowflake-cli/cicd/integrate-ci-cd)

---

*Document set version 1.0 | September 2026 | Owner: Solutions Engineering*
