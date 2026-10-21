# 07 — Migration Runbook: `ROOT_LOCATION` → `FROM`

Documents 01–06 repeatedly call this the gating prerequisite: legacy
`ROOT_LOCATION` apps cannot use Git, the container runtime, or multi-file
editing, so none of the Git workflow applies to them until they are migrated.
In a typical estate this is roughly three quarters of the apps, which makes it
the single largest piece of work in the programme.

This document is the procedure. Everything below was verified against Snowflake
10.34.101 on a real legacy app rather than inferred from documentation, because
two of the findings are the opposite of what you would reasonably assume.

---

## 1. The three things to know before you start

### You cannot convert an app in place

There is no `ALTER STREAMLIT … SET FROM`, and the natural workaround does not
work either:

```sql
ALTER STREAMLIT MY_DB.MY_SCHEMA.LEGACY_APP
    ADD VERSION "convert"
    FROM '@MY_DB.MY_SCHEMA.MY_REPO/branches/main/app/';
```

```
Attached stage not exists.
```

A `FROM`-model app stores its source in an embedded versioned stage inside the
Streamlit object. A legacy app has no such stage — it reads an external internal
stage instead — so there is nothing for a version to attach to. **Migration means
recreating the object.**

### `url_id` IS preserved — links and bookmarks survive

This is the good news, and it is worth knowing because the opposite assumption
causes teams to over-plan the comms around a migration.

`CREATE OR REPLACE STREAMLIT` on an existing name **keeps the same `url_id`**:

```
before migration   url_id = fj2dujqpblq5q4rtgsm6
after  migration   url_id = fj2dujqpblq5q4rtgsm6
```

So the app's Snowsight URL does not change. Existing bookmarks, links pasted
into Slack, and links embedded in other dashboards keep working. You do not need
a redirect or a "the dashboard has moved" announcement.

### Grants ARE dropped — silently

This is the bad news and it is the thing that will bite you.

```
before migration   OWNERSHIP -> ACCOUNTADMIN
                   USAGE     -> APP_SALES_VIEWER     <- present
after  migration   OWNERSHIP -> ACCOUNTADMIN
                                                      <- USAGE is gone
```

`CREATE OR REPLACE` is a replace: the privilege grants on the old object do not
carry over, and nothing warns you. The app keeps working for you, because you
own it, and stops working for every viewer. If you migrate on a Friday you find
out on Monday.

**Capture the grants before you replace the object.** Step 2 below does this.

---

## 2. The procedure

### Step 1 — Capture the current state

Run all of this and keep the output. You need it to verify the migration and to
restore grants.

```sql
-- Full definition. Save the output: main_file, query_warehouse, title,
-- external_access_integrations and secrets all have to be carried across.
DESCRIBE STREAMLIT MY_DB.MY_SCHEMA.LEGACY_APP;

-- Grants, as replayable statements. Run this and keep the generated SQL.
SHOW GRANTS ON STREAMLIT MY_DB.MY_SCHEMA.LEGACY_APP;

SELECT 'GRANT ' || "privilege"
       || ' ON STREAMLIT ' || "name"
       || ' TO ' || "granted_to" || ' ' || "grantee_name" || ';' AS replay_sql
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "privilege" <> 'OWNERSHIP';
```

`OWNERSHIP` is excluded deliberately — it cannot be granted on a Streamlit at
all, which is the subject of step 3.

Also record the `root_location` value. You will need it to find the source files
and, later, to clean up the orphaned stage.

### Step 2 — Get the source files into Git

The legacy app's source lives on the stage named in `root_location`:

```sql
LIST @MY_DB.MY_SCHEMA.LEGACY_STAGE/app_folder/;
```

```bash
# pull them down, commit them, push
snow stage copy @MY_DB.MY_SCHEMA.LEGACY_STAGE/app_folder/ ./apps/my_app/ --recursive
git add apps/my_app && git commit -m "Import my_app source ahead of migration"
git push
```

Then fetch into Snowflake, because `FETCH` is explicit:

```sql
ALTER GIT REPOSITORY GOVERNANCE.PROJECTS.MY_REPO FETCH;
```

**Check the dependency spec while the files are in front of you.** A legacy app
is warehouse-runtime and declares dependencies in `environment.yml`. If you are
also moving to the container runtime, that file is **silently ignored** and you
need a `requirements.txt` instead. An app that imported `plotly` via
`environment.yml` will deploy cleanly and then fail at import. See
[06 §3](06_tooling_and_runtimes.md).

Diagnostic: on a warehouse-runtime app, `DESCRIBE STREAMLIT` populates
`user_packages` from `environment.yml`. On a container-runtime app that column
comes back empty regardless, so it cannot confirm your pins — report
`st.__version__` from inside the app instead.

### Step 3 — Decide the owner *now*

Streamlit ownership **cannot be transferred**. There is no
`GRANT OWNERSHIP ON STREAMLIT` and no `ALTER STREAMLIT SET OWNER`; DCM rejects
it outright and plain SQL does not list `STREAMLIT` as a supported object type.
The role that executes `CREATE STREAMLIT` owns it permanently.

So the recreate in step 4 must be executed **as the role you want to own the
app**, or you will have to do the whole thing again:

```sql
USE ROLE APP_SALES_OWNER;      -- not ACCOUNTADMIN
```

This is why migration and re-owning are the same operation. Roughly 80% of apps
in a typical estate are admin-owned, and under owner's rights that hands the
owner's reach to every viewer — so the migration is also your chance to fix the
highest-severity finding in the audit. Doing it twice is pure waste.

That role needs `CREATE STREAMLIT` on the target schema and `USAGE` on the
warehouse, plus `READ` on the Git repository. See
[04 §3](04_rbac_and_ownership.md).

### Step 4 — Recreate with `FROM`

```sql
CREATE OR REPLACE STREAMLIT MY_DB.MY_SCHEMA.LEGACY_APP
    FROM '@GOVERNANCE.PROJECTS.MY_REPO/branches/main/apps/my_app/'
    MAIN_FILE = 'streamlit_app.py'
    QUERY_WAREHOUSE = ANALYTICS_WH
    TITLE = 'My App'
    COMMENT = 'Migrated from ROOT_LOCATION. Source: my-org/my-repo apps/my_app.';
```

Keep the **same fully qualified name**. That is what preserves `url_id`.

Note the path must be `branches/…`. `CREATE STREAMLIT` and
`ALTER STREAMLIT … ADD VERSION` accept **only** branch paths and reject `tags/`
and `commits/` with `Invalid git branch path`, despite the documented
`FROM { <snowgit_tag_uri> | <snowgit_commit_uri> }`. Auditability survives
anyway: the branch is resolved to a concrete commit and frozen onto the version
at create time. See [01 §2](01_dev_workflow_overview.md).

If the app should be DCM-managed instead, write a `DEFINE STREAMLIT` and deploy
the project rather than running `CREATE` by hand —
[03](03_promotion_pipeline.md). DCM is also the only route to a tag-pinned
release.

### Step 5 — Restore the grants

Replay the statements you generated in step 1:

```sql
GRANT USAGE ON STREAMLIT MY_DB.MY_SCHEMA.LEGACY_APP TO ROLE APP_SALES_VIEWER;
```

Then confirm, because this is the step whose omission is invisible:

```sql
SHOW GRANTS ON STREAMLIT MY_DB.MY_SCHEMA.LEGACY_APP;
```

Compare against the step 1 capture. Every non-`OWNERSHIP` row should be back.

### Step 6 — Verify the migration actually took

```sql
DESCRIBE STREAMLIT MY_DB.MY_SCHEMA.LEGACY_APP;
```

Four things to check:

| Check | Expected |
|---|---|
| Column count | 25, not 13. `root_location` gone, `live_version_location_uri` present |
| `default_version_git_commit_hash` | A 40-character SHA. This is the provenance you just bought |
| `url_id` | Unchanged from step 1 |
| `query_warehouse`, `title`, EAIs, secrets | Carried across from step 1 |

Then confirm the audit reclassifies it:

```sql
CALL GOVERNANCE.APPS.SP_AUDIT_STREAMLIT_APPS();

SELECT FULL_NAME, SOURCE_MODEL, PROVENANCE, OWNER_ROLE,
       SUBSTR(COMMIT_SHA, 1, 12) AS commit_sha, TIER, FINDINGS
FROM GOVERNANCE.APPS.V_STREAMLIT_INVENTORY_LATEST
WHERE FULL_NAME = 'MY_DB.MY_SCHEMA.LEGACY_APP';
```

`SOURCE_MODEL` should now read `FROM`, `IS_LEGACY_SOURCE` should be false, and
`PROVENANCE` should be `GIT_DIRECT`.

### Step 7 — Smoke-test, then clean up the orphan

Open the app. `PLAN` and `CREATE` both validate that the object can be created;
neither tests that the app *runs*. See [08](08_testing_and_validation.md).

Once you are satisfied, the old stage files are still sitting there — migration
does not remove them:

```sql
LIST @MY_DB.MY_SCHEMA.LEGACY_STAGE/app_folder/;   -- still present
REMOVE @MY_DB.MY_SCHEMA.LEGACY_STAGE/app_folder/;
```

Leave this until the app has been running for a few days. The stage is your
rollback.

---

## 3. Rollback

Until you remove the old stage files, rollback is the inverse of step 4:

```sql
CREATE OR REPLACE STREAMLIT MY_DB.MY_SCHEMA.LEGACY_APP
    ROOT_LOCATION = '@MY_DB.MY_SCHEMA.LEGACY_STAGE/app_folder'
    MAIN_FILE = 'streamlit_app.py'
    QUERY_WAREHOUSE = ANALYTICS_WH;
```

Then restore the grants again — rolling back drops them for exactly the same
reason the migration did.

---

## 4. Doing it in bulk

Migrating one app is a 20-minute job. Migrating sixty is a different exercise,
and the thing that makes it tractable is that most of them should not be
migrated at all.

Generate the worklist, sorted so the decisions are easy:

```sql
SELECT FULL_NAME,
       OWNER_ROLE,
       ROOT_LOCATION,
       AGE_DAYS,
       IS_UNNAMED,         -- machine-generated name: nobody ever cared about it
       IS_SCRATCH,         -- test/debug/temp naming
       IS_UNDOCUMENTED,
       FINDINGS
FROM GOVERNANCE.APPS.V_STREAMLIT_INVENTORY_LATEST
WHERE IS_LEGACY_SOURCE
ORDER BY IS_UNNAMED DESC, IS_SCRATCH DESC, AGE_DAYS DESC;
```

Then split it:

| Signal | Decision | Typical share |
|---|---|---|
| `IS_UNNAMED` or `IS_SCRATCH`, over a year old | **Retire.** Announce, wait, drop | Most of the list |
| Named, documented, has an identifiable owner | **Migrate** with this runbook | A minority |
| Named but the owner cannot be found | **Ask, then retire.** Silence is an answer | The awkward middle |

Two sequencing points that save real time:

**Batch by owner, not by app.** The expensive part is the conversation about who
owns it and what role should own it afterwards, not the SQL. Migrating five apps
for one team in one sitting costs barely more than migrating one.

**Do the retirements first.** They are faster, they shrink the list visibly, and
a worklist that is dropping makes the programme look like it is working — which
matters when you are asking a team for time.

---

## 5. What this does not cover

Apps you cannot describe at all — typically arriving via a shared database or an
expired marketplace listing trial — cannot be migrated by you, because you do
not own them:

```sql
SELECT FULL_NAME, DESCRIBE_ERROR
FROM GOVERNANCE.APPS.V_STREAMLIT_INVENTORY_LATEST
WHERE DESCRIBE_ERROR IS NOT NULL;
```

The audit records them rather than dropping the row, because an app you cannot
open is still your problem when someone asks why it is broken. The action is to
find out who provisioned the share, not to migrate.

---

Previous: [06 — Tooling and Runtimes](06_tooling_and_runtimes.md) ·
Next: [08 — Testing and Validation](08_testing_and_validation.md)
