---
name: migrate-legacy-streamlit-apps
description: "Triage the legacy estate and migrate ROOT_LOCATION apps to the modern Git-sourced model, or retire them."
parent_skill: deploy-streamlit-practice
---

# Phase 5 — Migrate

**Rationale:** `streamlit_strategy_v1/07_migration_runbook.md`;
`00_getting_started.md` step 3.

Legacy `ROOT_LOCATION` apps cannot use Git integration, container runtime, or
multi-file editing. In a typical estate they are the majority, which makes this
a prerequisite for those apps rather than a tidy-up.

**The cheapest migration is a retirement.** Most of a sprawling estate is
abandoned. Triage before touching anything.

## Workflow

### Step 1: Triage, do not migrate

Work from the phase 1 remediation queue. Sort each app into one of three
buckets:

| Bucket | Signal | Action |
|---|---|---|
| Retire | no recent queries, no named owner, over a year old | drop, after notice |
| Ask then retire | owner exists but app looks dormant | one email, a deadline, then drop |
| Migrate | actively used and someone depends on it | the procedure below |

**⚠️ Stop and present the triage.** Per-app, with the evidence. Retirement is
irreversible and this is the decision the user must own.

**Do the retirements first.** They shrink the migration worklist, and nothing is
more wasteful than carefully migrating an app that nobody opens.

### Step 2: Batch by owner, not by app

Migration needs a conversation with whoever depends on the app. Batching by
owner means one conversation covers several apps. Batching by app means one
conversation each, which is how migration programmes stall.

### Step 3: Capture the grants — before anything else

`CREATE OR REPLACE STREAMLIT` **silently drops privilege grants.** The owner
still works, so the app looks fine to whoever migrated it; every viewer is
locked out. Capture first and keep the replay SQL:

```sql
SHOW GRANTS ON STREAMLIT <DB>.<SCHEMA>.<LEGACY_APP>;
SELECT 'GRANT ' || "privilege"
       || ' ON STREAMLIT ' || "name"
       || ' TO ' || "granted_to" || ' ' || "grantee_name" || ';' AS replay_sql
  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
 WHERE "privilege" <> 'OWNERSHIP';
```

`OWNERSHIP` is excluded because it cannot be granted on a Streamlit at all.

### Step 4: Get the source out

There is no in-place conversion. `ALTER STREAMLIT ... ADD VERSION FROM` on a
legacy app fails with `Attached stage not exists.` — a legacy app has no
embedded versioned stage to add a version to.

Pull the files from the `root_location` stage, commit them to the repo, push,
and `FETCH`.

### Step 5: Recreate as the owner role

**⚠️ Approval gate per app.**

Run this **as the intended functional owner role**, because ownership is
permanent and this is the only moment it can be set.

```sql
CREATE OR REPLACE STREAMLIT <DB>.<SCHEMA>.<APP>
    FROM '@<repo>/branches/main/<path>/'
    MAIN_FILE = 'streamlit_app.py'
    QUERY_WAREHOUSE = <WH>
    TITLE = '<title>';
```

Note `branches/` here, not `commits/`. `CREATE STREAMLIT FROM` resolves a branch
path to a concrete SHA at create time and pins it on the version, so
auditability is preserved. This is the **opposite** of the DCM rule in phase 3 —
see the mechanism inversion in `references/gotchas.md`. Getting it backwards
either hard-fails or silently loses the trail.

### Step 6: Replay the grants and verify

Run the captured replay SQL, then prove the migration landed:

```sql
SHOW VERSIONS IN STREAMLIT <DB>.<SCHEMA>.<APP>;   -- git_commit_hash populated
SHOW GRANTS ON STREAMLIT <DB>.<SCHEMA>.<APP>;     -- viewers restored, owner correct
DESCRIBE STREAMLIT <DB>.<SCHEMA>.<APP>;           -- url_id unchanged
```

**`url_id` survives `CREATE OR REPLACE`.** Links and bookmarks keep working and
no user comms are needed. This is counter-intuitive — most people assume
recreation breaks links, and that assumption is the most common reason a
migration gets deferred. Verify it and then say so, because it removes the main
objection.

### Step 7: Leave the old stage alone for now

The old `ROOT_LOCATION` stage files are not removed. That is orphaned storage,
and it is also your rollback. `REMOVE @stage/path/` after a few days of the
migrated app being used, not on the same day.

### Step 8: Register and record

Register each migrated app (phase 4) and update `state.json` with what moved and
what was retired. The audit will reflect it on the next run — re-run it to
confirm the source model actually changed.

## Output

A smaller, modern estate: legacy apps either retired or Git-sourced with grants
intact and links unbroken. Progress recorded per batch.

## Next

**Continue** to `phases/6-harden/SKILL.md`.

Migration is usually iterative across sessions. Record the batch state so the
next session resumes instead of re-triaging.
