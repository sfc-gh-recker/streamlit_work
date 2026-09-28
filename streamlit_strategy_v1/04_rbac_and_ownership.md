# 04 — RBAC and Ownership

## 1. Owner's rights is the whole security model

A Streamlit app runs with the privileges of **its owner role**, not the viewer's. Every person who opens the dashboard reaches data through the owner's privileges.

That single fact drives everything in this document:

- The owner role is the blast radius. Whatever it can read, the app can read, and therefore whatever it can read can potentially be surfaced to any viewer.
- `CURRENT_ROLE()` inside the app returns the **owner's** role. Row access policies keyed on `CURRENT_ROLE()` do **not** segment viewers under owner's rights.
- Viewers need no grants on the underlying data. That is the main ergonomic benefit, and the right default for a reporting dashboard.

Measured on the audited account: **64 of 82 apps (78%) are owned by `ACCOUNTADMIN`, `SYSADMIN`, or `SECURITYADMIN`.** Each of those hands admin-level reach to everyone who can open the dashboard. This is the single highest-severity finding in the estate, ahead of the provenance gap.

```sql
SELECT FULL_NAME, OWNER_ROLE, AGE_DAYS
FROM GOVERNANCE.APPS.V_STREAMLIT_INVENTORY_LATEST
WHERE IS_ADMIN_OWNED
ORDER BY AGE_DAYS DESC;
```

## 2. Ownership cannot be transferred

This is the most consequential verified limitation in the entire set, because it inverts the obvious remediation plan.

**Attempt 1 — declaratively, in a DCM project:**

```sql
GRANT OWNERSHIP ON STREAMLIT MY_DB.SERVE.MY_APP TO ROLE APP_OWNER;
```

```
Unsupported feature GRANT/REVOKE OWNERSHIP ON STREAMLIT
```

Observed during `PLAN`: 23 of 24 statements compiled; only this one failed.

**Attempt 2 — imperatively, in SQL:** STREAMLIT is absent from the supported `object_type` list for `GRANT OWNERSHIP`. There is also no `ALTER STREAMLIT … SET OWNER`.

So there is no transfer path at all. Per the owner's-rights documentation, *"when an app is created, it runs with the role of the user who originally created the app"* — and that is permanent.

### Two consequences

**For new apps:** the deploying role *is* the owner, forever. The functional owner role must be the role that deploys. In DCM that is the target's `project_owner`:

```yaml
targets:
  prod:
    project_owner: APP_MERCH_OWNER     # this decides what viewers can reach
```

**For the 65 admin-owned apps:** they cannot be re-owned. They must be **recreated** under the correct role. Combine this with the legacy `ROOT_LOCATION` migration from [02](02_git_strategy.md) — both require recreating the app, so do them in one pass rather than twice.

Be blunt about this with anyone who assumes re-owning is a one-line fix. It is a redeploy of every production app, and it is better to say so at planning time than to discover it mid-remediation.

### The architectural consequence: split the DCM project in two

This limitation has a non-obvious knock-on effect that is worth designing for up front.

A single DCM project that creates *both* the infrastructure (database, schemas, tables, roles) *and* the Streamlit app must be owned by a role privileged enough to do all of it — realistically something with `CREATE DATABASE`. But because the deploying role permanently becomes the app owner, that same broad role then becomes what every dashboard viewer reaches data through. The two requirements pull in opposite directions.

Observed concretely: the reference app in this repo was deployed by a single DCM project whose `project_owner` was `ACCOUNTADMIN`. Everything about it is otherwise correct — Git-backed, CI/CD-deployed, least-privilege serving view, full provenance. The certification procedure still refused it:

```
CALL GOVERNANCE.APPS.SP_CERTIFY_APP('FANATICS_MERCH_DEV.SERVE.MERCH_PERFORMANCE', 'Rich Ecker');

NOT CERTIFIED: owned by an admin role -- viewers would inherit admin rights.
Ownership cannot be transferred; recreate under a functional role
```

That is the correct outcome, and it cannot be fixed by granting anything.

The resolution is to split along the ownership boundary:

| Project | Creates | `project_owner` | Why |
|---|---|---|---|
| **Infrastructure** | Database, schemas, tables, views, roles, grants | `APP_PLATFORM_DEPLOYER` | Needs broad DDL privileges |
| **App** | Only the `DEFINE STREAMLIT` | `APP_<DOMAIN>_OWNER` | Becomes the app owner, so must stay least-privilege |

The app project's owner role needs very little: `USAGE` on the database and schema, `CREATE STREAMLIT` on the schema, `SELECT` on the serving view, `USAGE` on the warehouse and — for container runtime — the compute pool. That is precisely the least-privilege set from section 3, which is the point.

Deploy infrastructure first, then the app:

```bash
snow dcm deploy --from ./infra    --target prod   # as APP_PLATFORM_DEPLOYER
snow dcm deploy --from ./app      --target prod   # as APP_MERCH_OWNER
```

The cost is two projects and an ordering dependency between them. The benefit is that the role your executives' dashboard runs as cannot create a database. Given that ownership is permanent, paying this cost at design time is much cheaper than discovering it after a hundred apps are deployed.

## 3. Role design

Four roles per app domain, each with one job.

```
SYSADMIN
└── APP_PLATFORM_ADMIN
    ├── APP_DEPLOYER_PROD        CI/CD service identity; owns prod apps
    ├── APP_<DOMAIN>_OWNER       functional owner; the app runs as this
    ├── SIS_DEVELOPER            builds apps in DEV; no prod access
    └── APP_<DOMAIN>_VIEWER      opens the dashboard; no data grants
```

| Role | Holds | Granted to | Never |
|---|---|---|---|
| `APP_DEPLOYER_PROD` | Deploy privileges, `EXECUTE DCM PROJECT` | CI/CD service users **only** | Individual developers |
| `APP_<DOMAIN>_OWNER` | `SELECT` on serving views only | Used as the deploying role for that app | Broad data access |
| `SIS_DEVELOPER` | `CREATE STREAMLIT` in DEV | Developers | Any privilege on PROD |
| `APP_<DOMAIN>_VIEWER` | `USAGE` on the app object | Business users | Grants on underlying tables |

### Functional owner: least privilege is the point

The owner role should read the **serving view and nothing else**. Deliberately excluding the base schema means a bug in the app cannot expose base tables.

```sql
CREATE ROLE IF NOT EXISTS APP_MERCH_OWNER;

GRANT USAGE  ON DATABASE FANATICS_MERCH              TO ROLE APP_MERCH_OWNER;
GRANT USAGE  ON SCHEMA   FANATICS_MERCH.SERVE        TO ROLE APP_MERCH_OWNER;
GRANT SELECT ON VIEW     FANATICS_MERCH.SERVE.V_MERCH_PERFORMANCE
                                                     TO ROLE APP_MERCH_OWNER;
GRANT USAGE  ON WAREHOUSE MY_WH                      TO ROLE APP_MERCH_OWNER;

-- Container runtime only. Omitting this is a common cause of an app that
-- deploys cleanly and then fails to start.
GRANT USAGE  ON COMPUTE POOL SYSTEM_COMPUTE_POOL_CPU TO ROLE APP_MERCH_OWNER;
```

Note there is **no** grant on `FANATICS_MERCH.CORE`.

### Viewer

```sql
CREATE ROLE IF NOT EXISTS APP_MERCH_VIEWER;

GRANT USAGE ON DATABASE  FANATICS_MERCH       TO ROLE APP_MERCH_VIEWER;
GRANT USAGE ON SCHEMA    FANATICS_MERCH.SERVE TO ROLE APP_MERCH_VIEWER;
GRANT USAGE ON STREAMLIT FANATICS_MERCH.SERVE.MERCH_PERFORMANCE
                                              TO ROLE APP_MERCH_VIEWER;
GRANT USAGE ON WAREHOUSE MY_WH                TO ROLE APP_MERCH_VIEWER;
```

To make certified apps visible automatically as they are added:

```sql
GRANT USAGE ON FUTURE STREAMLITS IN SCHEMA FANATICS_MERCH.SERVE
  TO ROLE APP_MERCH_VIEWER;
```

In managed-access schemas, future grants may need administering explicitly.

## 4. The self-service unblock

"Non-admin users cannot create apps" is a real blocker with a small fix. No admin role is required:

```sql
CREATE ROLE IF NOT EXISTS SIS_DEVELOPER;

GRANT USAGE           ON DATABASE  APP_DB        TO ROLE SIS_DEVELOPER;
GRANT USAGE           ON SCHEMA    APP_DB.APPS   TO ROLE SIS_DEVELOPER;
GRANT CREATE STREAMLIT ON SCHEMA   APP_DB.APPS   TO ROLE SIS_DEVELOPER;
GRANT USAGE           ON WAREHOUSE APP_WH        TO ROLE SIS_DEVELOPER;

-- container runtime only
GRANT USAGE ON COMPUTE POOL APP_POOL             TO ROLE SIS_DEVELOPER;
```

### Two grants people ask for and usually do not need

**`CREATE STAGE`** is required only for the legacy `ROOT_LOCATION` pattern. On the `FROM` model the app uses an embedded versioned stage inside the object. If users are blocked on stage creation, **migrating to `FROM` removes the blocker** rather than requiring a new privilege — a better outcome, since it also unlocks Git integration and the container runtime.

**`CREATE STREAM`** is required only if the app itself creates or reads streams. Check whether that is genuinely the case before adding it to a baseline developer role; the requirement is often inherited from a legacy pattern rather than a real need. Grant it per-app when justified:

```sql
GRANT CREATE STREAM ON SCHEMA APP_DB.APPS TO ROLE SIS_DEVELOPER;
```

Worth auditing the actual request rather than accepting the stated one — it is a chance to remove a privilege instead of adding one.

## 5. Row access policies and context functions

If a warehouse-runtime app calls any context function, or reads a table with a row access policy, grant the owner role the global `READ SESSION` privilege:

```sql
GRANT READ SESSION ON ACCOUNT TO ROLE APP_MERCH_OWNER;
```

Without it the app fails at runtime with an error that does not obviously point at this.

### When you need per-viewer segmentation

Owner's rights cannot do it. `CURRENT_ROLE()` returns the owner's role, so a policy keyed on it evaluates identically for every viewer.

| | Owner's rights (default) | Caller's rights |
|---|---|---|
| Runs as | Owner role | Viewer's role |
| `CURRENT_ROLE()` | Owner | **Viewer** |
| Viewer data grants | Not needed | **Required for every viewer** |
| Row access policies segment viewers | **no** | yes |
| Setup cost | Low | Higher |
| Right for | Dashboards, reporting — most apps | Per-user data segmentation |

```python
conn = st.connection("snowflake", type="snowflake-callers-rights")
```

Restricted caller's rights requires the **container** runtime. Start with owner's rights; move only when you genuinely need per-viewer filtering, because the setup cost is real — every viewer needs direct grants on the underlying data.

## 6. Additional owner's-rights restrictions

Warehouse-runtime apps run as stored procedures and inherit those restrictions:

- Limits on which built-in functions can be called
- `DESCRIBE`, `SHOW`, and `LIST` are affected
- Limits on statement types
- `ALTER USER` is not available

**Container-runtime apps are not stored procedures** and avoid these restrictions. If an app needs `SHOW`-style introspection — an admin or catalog app, for instance — that is a concrete reason to choose the container runtime.

## 7. Separation of duties

| Principle | Implementation |
|---|---|
| No human deploys to PROD | `APP_DEPLOYER_PROD` granted to service users only |
| The owner role is scoped | Serving views only, never base schemas |
| Viewer access is per-object | `USAGE` on the app, not blanket database grants |
| Developers cannot reach PROD | `SIS_DEVELOPER` has no PROD privileges |
| `ACCOUNTADMIN` is break-glass | Never a deploying role, never an app owner |
| Audit trail | `ACCESS_HISTORY`, plus DCM deployment history |

The last row is worth acting on rather than just asserting. Because the owner role determines the app's reach, reviewing who holds each `APP_*_OWNER` role is a higher-value periodic check than reviewing who can open the dashboard.

---

Previous: [03 — Promotion Pipeline](03_promotion_pipeline.md) · Next: [05 — App Governance and Registry](05_app_governance_registry.md)
