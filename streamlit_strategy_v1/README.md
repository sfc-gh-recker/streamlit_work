# Streamlit Development & Management Strategy

## Overview

This documentation set defines how Streamlit apps are developed, governed, promoted, and retired on Snowflake. It is written to be handed to a team that has none of this in place and has to stand up a Streamlit practice from zero.

Every limitation recorded here was verified empirically against a live Snowflake account, not taken from documentation. Where a documented capability turned out not to work as expected, that is called out with the actual error.

**Start at [00 — Getting Started](00_getting_started.md)** for the ordered, executable setup sequence. The numbered documents after it explain why the practice is shaped the way it is, and are reference rather than reading order.

---

## Documents

| # | Document | Covers |
|---|---|---|
| 0 | [**Getting Started**](00_getting_started.md) | **Day-zero runbook: privileges, ordered setup steps, first-team onboarding** |
| 1 | [Development Workflow Overview](01_dev_workflow_overview.md) | The problem, the provenance gate, the three-tier model, lifecycle |
| 2 | [Git Strategy](02_git_strategy.md) | Git repositories, provenance, branching, CODEOWNERS, custom SQL |
| 3 | [Promotion Pipeline](03_promotion_pipeline.md) | DCM Projects, `DEFINE STREAMLIT`, DEV/TEST/PROD, CI/CD, rollback |
| 4 | [RBAC and Ownership](04_rbac_and_ownership.md) | Owner's rights, functional roles, the self-service grant set |
| 5 | [App Governance and Registry](05_app_governance_registry.md) | Sanctioned vs side project, registry, certification, support boundary |
| 6 | [Tooling and Runtimes](06_tooling_and_runtimes.md) | Workspaces, CLI, runtime choice, dependency pinning, observability |
| 7 | [Migration Runbook](07_migration_runbook.md) | `ROOT_LOCATION` → `FROM`: the gating prerequisite, step by step, including bulk triage |
| 8 | [Testing and Validation](08_testing_and_validation.md) | The six layers, from static checks to provenance assertions. Closes the "`PLAN` does not test that the app runs" gap |

### Reading paths

| You are | Read |
|---|---|
| Standing this up from scratch | 00, then 01, then 04 before creating anything |
| Inheriting an existing estate | 00 §1 to measure, then 07 to triage, then 05 |
| Building the CI/CD pipeline | 03, then 08, then 02 §7 |
| Debugging a broken app | 08 §5, then 06 §3 |
| Deciding whether to use Streamlit at all | 06 §9 |

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
| `CREATE STREAMLIT FROM @git_repo/branches/main/` | populated | Commit hash on the app object; per-version ledger in `SHOW VERSIONS IN STREAMLIT` |
| DCM `DEFINE STREAMLIT FROM 'asset://…'` | empty | The `source_file_path` of the latest row in `SHOW DEPLOYMENTS IN DCM PROJECT` |
| Built in Snowsight | empty | none |

Both governed paths are acceptable. An app with neither is a side project, and that is the line where platform support stops.

Two caveats that change how you deploy, both verified against 10.34.101 rather than
taken from the documentation:

- The `git_commit_hash` column of `SHOW DEPLOYMENTS IN DCM PROJECT` never
  populates. Deploy DCM projects from `@repo/tags/<tag>/` or
  `@repo/commits/<sha>/`, because the `FROM` path is the only Git evidence
  retained; a `branches/` path records a moving pointer.
- `CREATE STREAMLIT` and `ALTER STREAMLIT … ADD VERSION` accept **only**
  `branches/` paths and reject `tags/` and `commits/`. So tag-pinned releases have
  to go through DCM.

See [`01_dev_workflow_overview.md`](01_dev_workflow_overview.md) for the full
matrix.

---

## Verified limitations

These shape the design. Each cost a debugging cycle to find.

| Limitation | Design consequence |
|---|---|
| `GRANT OWNERSHIP ON STREAMLIT` unsupported in DCM **and** in SQL | Ownership cannot be transferred. The deploying role owns the app permanently. Admin-owned apps must be **recreated**, not re-granted. See [04](04_rbac_and_ownership.md). |
| DCM Jinja variables do not reach Streamlit Python files | The app must infer its environment at runtime via `CURRENT_DATABASE()`. Templating a database name ships a PROD app reading DEV data, silently. See [03](03_promotion_pipeline.md). |
| Legacy `ROOT_LOCATION` apps cannot use Git integration or the container runtime | Roughly three quarters of a typical estate is legacy. Migration to `FROM` is a **prerequisite**, not a detail. See [02](02_git_strategy.md). |
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
| No provenance at all | most of the estate | ~98% |
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
