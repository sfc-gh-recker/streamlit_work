# 05 — App Governance and Registry

## 1. What governance has to answer

Three questions, asked constantly, currently unanswerable:

1. **Which apps exist?** Nobody has a list.
2. **Which ones matter?** Everyone's answer differs.
3. **Who fixes this one when it breaks?** Defaults to the platform team.

The rest of this document is machinery for answering those with queries instead of opinions.

## 2. There is no `ACCOUNT_USAGE` view for Streamlit

Verified: the `ACCOUNT_USAGE` schema exposes `STAGES`, `TAGS`, `TAG_REFERENCES`, and `OBJECT_DEPENDENCIES`, but **nothing for Streamlit**. `GRANTS_TO_ROLES` returns zero rows for `granted_on ILIKE '%STREAMLIT%'`.

The only sources of truth are:

| Source | Gives you | Shape |
|---|---|---|
| `SHOW STREAMLITS IN ACCOUNT` | The object list | One row per app |
| `DESCRIBE STREAMLIT <fqn>` | Per-app detail incl. provenance | One row, **variable columns** |
| `SHOW ENTITIES IN DCM PROJECT <p>` | Apps managed by a project | Per-project |

None is a queryable view, so an inventory must be **materialized** by looping `DESCRIBE` over every app. That is [`audit/streamlit_inventory.sql`](../audit/streamlit_inventory.sql).

Two implementation details that matter if you modify it:

- **`DESCRIBE STREAMLIT` returns a different column set for legacy vs current apps** (13 vs 25 columns). Selecting a named column that does not exist is a compile error, so the procedure wraps results in `OBJECT_CONSTRUCT(*)` and reads keys out of the VARIANT — a missing key yields NULL instead of failing.
- **Snowflake regex rejects the `(?i)` inline flag.** Use `REGEXP_LIKE(col, pattern, 'i')`.

## 3. Classification

Each app is scored on signals that are all derived, never self-reported.

| Signal | Detection | Why it matters |
|---|---|---|
| **No provenance** | No commit hash **and** not DCM-managed | No diff, no rollback, no review |
| **Legacy source model** | `root_location` present | Cannot use Git or container runtime |
| **Admin-owned** | Owner in (`ACCOUNTADMIN`, `SYSADMIN`, `SECURITYADMIN`) | Viewers inherit admin reach |
| **Never named** | Name matches `^[A-Z0-9_]{16}$` | Created and abandoned in Snowsight |
| **Undocumented** | Comment null or Snowsight's JSON blob | Nobody knows what it is for |
| **Duplicate** | Title `Copy of…` / `Backup of…` | Unclear which is authoritative |
| **Scratch** | Name matches test/debug/minimal/repro | Should have been deleted |
| **Unpinned** | No exact `streamlit==` pin | Behaviour can change with no code edit |
| **Stale** | Age over one year | Probably abandoned |
| **Not inspectable** | `DESCRIBE` failed | You cannot audit it, but you still own the ticket |

That last row is deliberate. The audited account had one app arriving via an expired listing trial — `22000 / Listing trial time limit exceeded`. An app you cannot open is still your problem, so the audit records the row with the error rather than dropping it.

### Provenance: accept either path

The trap worth restating, because getting it wrong misclassifies your best apps:

```sql
-- governed if EITHER holds
GIT_COMMIT_HASH IS NOT NULL    -- deployed direct from a Git repository
OR DCM_PROJECT IS NOT NULL     -- deployed through a DCM project
```

A DCM-deployed app has **no** commit hash on the object — its `source_location_uri` is `asset://<name>`. Keying the gate on the hash alone reports a fully CI/CD-managed app as ungoverned. Verified on the audited account: one app of each kind, both correctly certified only after the cross-reference was added.

### Tier assignment

```sql
CASE
  WHEN describe_failed                      THEN 'REMEDIATE'
  WHEN source_model = 'ROOT_LOCATION'       THEN 'REMEDIATE'
  WHEN git_hash IS NOT NULL
       OR dcm_project IS NOT NULL           THEN 'CERTIFIED'
  WHEN owner NOT IN (admin roles)
       AND NOT machine_named                THEN 'TEAM'
  ELSE 'EXPLORE'
END
```

## 4. Running it

```sql
CALL GOVERNANCE.APPS.SP_AUDIT_STREAMLIT_APPS();
SELECT * FROM GOVERNANCE.APPS.V_STREAMLIT_SPRAWL_SUMMARY;
```

| View | Use |
|---|---|
| `V_STREAMLIT_INVENTORY_LATEST` | Full detail, latest run |
| `V_STREAMLIT_SPRAWL_SUMMARY` | Headline numbers — the slide |
| `V_STREAMLIT_REMEDIATION_QUEUE` | Worst offenders, scored |
| `V_STREAMLIT_BY_DATABASE` | Which teams generate the sprawl |

History is retained per run, which is what lets you show a trend — "ungoverned app count down 40% this quarter" is a far better governance report than a static count. A weekly task refreshes it:

```sql
ALTER TASK GOVERNANCE.APPS.TSK_AUDIT_STREAMLIT_APPS RESUME;
```

## 5. The registry

The audit records what **is**. The registry records what is **intended** — the facts no amount of introspection can derive: who owns this in the business, who to page, what the retirement date is.

```sql
CREATE TABLE IF NOT EXISTS GOVERNANCE.APPS.APP_REGISTRY (
    FULL_NAME            VARCHAR PRIMARY KEY,   -- db.schema.app
    TITLE                VARCHAR,
    DESCRIPTION          VARCHAR,
    DOMAIN               VARCHAR,               -- Commerce, Finance, Supply Chain
    PERSONA              VARCHAR,               -- Exec, Analyst, Ops
    TIER                 VARCHAR,               -- EXPLORE | TEAM | CERTIFIED
    BUSINESS_OWNER       VARCHAR,               -- a person
    TECHNICAL_OWNER      VARCHAR,               -- a person
    SUPPORT_GROUP        VARCHAR,               -- who gets paged
    OWNER_ROLE           VARCHAR,               -- functional role it runs as
    VIEWER_ROLE          VARCHAR,
    DATA_CLASSIFICATION  VARCHAR,               -- Public, Internal, Confidential
    COST_CENTER          VARCHAR,
    SOURCE_REPO          VARCHAR,
    SOURCE_PATH          VARCHAR,
    DCM_PROJECT          VARCHAR,
    CERTIFICATION        VARCHAR,               -- CERTIFIED | PENDING | NONE
    CERTIFIED_BY         VARCHAR,
    CERTIFIED_ON         DATE,
    LAST_REVIEWED        DATE,
    REVIEW_INTERVAL_DAYS NUMBER DEFAULT 180,
    RETIREMENT_DATE      DATE,
    APP_URL              VARCHAR,
    ICON                 VARCHAR
);
```

### Registry plus audit is the interesting part

Neither alone is enough. Joined, they surface the contradictions:

```sql
-- Apps claiming to be certified that the audit says have no provenance
SELECT r.FULL_NAME, r.BUSINESS_OWNER, r.CERTIFICATION, i.PROVENANCE, i.FINDINGS
FROM GOVERNANCE.APPS.APP_REGISTRY r
JOIN GOVERNANCE.APPS.V_STREAMLIT_INVENTORY_LATEST i USING (FULL_NAME)
WHERE r.CERTIFICATION = 'CERTIFIED' AND i.IS_UNGOVERNED;

-- Apps in the estate that nobody has registered
SELECT i.FULL_NAME, i.OWNER_ROLE, i.AGE_DAYS, i.FINDINGS
FROM GOVERNANCE.APPS.V_STREAMLIT_INVENTORY_LATEST i
LEFT JOIN GOVERNANCE.APPS.APP_REGISTRY r USING (FULL_NAME)
WHERE r.FULL_NAME IS NULL AND i.TIER <> 'EXPLORE';

-- Registered apps that no longer exist
SELECT r.FULL_NAME, r.BUSINESS_OWNER, r.SUPPORT_GROUP
FROM GOVERNANCE.APPS.APP_REGISTRY r
LEFT JOIN GOVERNANCE.APPS.V_STREAMLIT_INVENTORY_LATEST i USING (FULL_NAME)
WHERE i.FULL_NAME IS NULL;

-- Overdue review
SELECT FULL_NAME, BUSINESS_OWNER, LAST_REVIEWED
FROM GOVERNANCE.APPS.APP_REGISTRY
WHERE DATEADD('day', REVIEW_INTERVAL_DAYS, LAST_REVIEWED) < CURRENT_DATE();
```

The first query is the one that matters politically. It finds apps somebody declared production-ready that cannot actually prove their origin — and it finds them without anyone having to make an accusation.

## 6. Tagging

Streamlit **is** a taggable object, so certification can be machine-readable on the object:

```sql
CREATE TAG IF NOT EXISTS GOVERNANCE.APPS.APP_LIFECYCLE
  ALLOWED_VALUES 'EXPLORE', 'TEAM', 'CERTIFIED', 'RETIRED';

ALTER STREAMLIT FANATICS_MERCH.SERVE.MERCH_PERFORMANCE
  SET TAG GOVERNANCE.APPS.APP_LIFECYCLE = 'CERTIFIED';
```

**But DCM `ATTACH TAG` does not support STREAMLIT.** Supported targets are DATABASE, SCHEMA, TABLE, VIEW, DYNAMIC TABLE, FUNCTION, PROCEDURE, STAGE, TASK, ROLE, DATABASE ROLE, WAREHOUSE. So tags on apps cannot be declared in the DCM project and reconciled on each deployment.

Consequence for design: **the registry table is the declarative record; the tag is a derived artifact** applied imperatively as a post-certification step. Do not make the tag the source of truth — it can drift, and nothing reconciles it.

## 7. Certification

What is being certified is not that the dashboard looks right. It is that **the platform team is willing to be paged for it.** Framed that way, the checklist is obvious.

| # | Check | Verify with |
|---|---|---|
| 1 | Source in an approved repository | `SOURCE_REPO` set, commit or DCM project present |
| 2 | Deployment reproducible from source | `snow dcm plan` clean from a fresh clone |
| 3 | Source model is `FROM`, not legacy | `DESCRIBE STREAMLIT` has no `root_location` |
| 4 | Owner is a functional role | Not an individual, not an admin role |
| 5 | Owner role is least-privilege | Serving views only, no base schemas |
| 6 | Viewer role correct | `USAGE` only, no underlying data grants |
| 7 | Exact version pins | `requirements.txt` / `environment.yml` |
| 8 | Environment inferred at runtime | No hardcoded database in app source |
| 9 | Queries parameterized | No f-string SQL |
| 10 | Sensitive data reviewed | Classification recorded |
| 11 | Business and technical owner named | Registry populated |
| 12 | Support group and escalation defined | Registry populated |
| 13 | Monitoring enabled | Event table configured |
| 14 | Review and retirement date set | Registry populated |

Checks 1–9 are mechanically verifiable. 10–14 are human commitments — which is exactly why they live in a registry rather than being inferred.

## 8. The support boundary

State it once, publicly, and let the query arbitrate:

> The platform team supports apps in the catalog. An app is in the catalog when it is certified. An app can be certified when it can prove where its code came from. Everything else is supported by whoever built it — and the path to changing that is a pull request.

This works because it is not a judgement about importance. Nobody has to argue their app matters; they have to put it in Git. And when an owner wants support, the remedy is self-service and documented rather than a negotiation with the platform team.

---

Previous: [04 — RBAC and Ownership](04_rbac_and_ownership.md) · Next: [06 — Tooling and Runtimes](06_tooling_and_runtimes.md)
