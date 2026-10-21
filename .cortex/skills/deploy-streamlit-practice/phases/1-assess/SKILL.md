---
name: assess-streamlit-estate
description: "Measure the existing Streamlit estate before changing anything: deploy the audit, run it, and record the baseline."
parent_skill: deploy-streamlit-practice
---

# Phase 1 — Assess

**Rationale:** `streamlit_strategy_v1/00_getting_started.md` steps 1–2.

Read-only apart from creating the governance schema and the audit objects. Say
that when proposing it — it is the phase with the lowest bar to starting, and it
produces the numbers that justify the rest.

## Prerequisites

Check these and report which are missing rather than failing mid-way:

| Need | Why |
|---|---|
| A role that can `SHOW STREAMLITS IN ACCOUNT` | the inventory loop |
| `CREATE DATABASE` or an existing governance database | somewhere to put the audit |
| `snow` CLI with a working connection | everything below |
| A warehouse | the audit procedure runs SQL |

`ACCOUNTADMIN` is sufficient and is what most operators will start with. A
narrower role works provided it can see apps account-wide — and if it cannot,
the audit will quietly under-report rather than error, which is worse. Confirm
the visible app count against expectation before trusting the baseline.

## Workflow

### Step 1: Deploy the audit

**⚠️ Approval gate.** This creates `GOVERNANCE.APPS` plus a procedure and four
views. Show the object list before running.

```bash
snow sql -f audit/streamlit_inventory.sql -c <CONNECTION> --warehouse <WH>
```

Then verify the objects exist rather than trusting the exit code:

```sql
SHOW PROCEDURES LIKE 'SP_AUDIT_STREAMLIT_APPS' IN SCHEMA GOVERNANCE.APPS;
SHOW VIEWS LIKE 'V_STREAMLIT%' IN SCHEMA GOVERNANCE.APPS;
```

### Step 2: Run it

```sql
CALL GOVERNANCE.APPS.SP_AUDIT_STREAMLIT_APPS();
```

The procedure loops `SHOW` + `DESCRIBE` per app because there is no
`ACCOUNT_USAGE.STREAMLITS` view. On a large estate this takes a few minutes.

### Step 3: Read the baseline

```sql
SELECT * FROM GOVERNANCE.APPS.V_STREAMLIT_SPRAWL_SUMMARY;
SELECT SOURCE_MODEL, COUNT(*) FROM GOVERNANCE.APPS.V_STREAMLIT_INVENTORY_LATEST
 GROUP BY 1 ORDER BY 2 DESC;
SELECT * FROM GOVERNANCE.APPS.V_STREAMLIT_REMEDIATION_QUEUE LIMIT 20;
```

Interpret with care — two numbers are routinely misread:

- **`governed_not_traceable`** is apps managed by a DCM project deployed from a
  *branch* path. They are governed but cannot prove which commit shipped. This
  is a different problem from having no provenance at all, and a different fix.
- **`workspace_preview_apps`** point at `versions/head`, a moving pointer. The
  remediation is promotion to Git, not a source-model migration.

If `UNKNOWN` is more than a couple of apps, suspect the detection bug in
`references/gotchas.md` rather than a genuinely exotic estate.

### Step 4: Record it

Write `baseline` to `state.json` per `references/state.md`. Exclude any apps
this rollout deploys itself, and record which names were excluded — counting
them flatters the before-picture, and the delta is the point.

**⚠️ Stop and present.** Report the baseline as a short table: total, no
provenance, legacy source model, admin-owned, untitled, over a year old. Name
the single largest remediation class, because that is what determines whether
phase 5 is a side quest or the main event.

## Output

`GOVERNANCE.APPS` audit objects, one inventory snapshot, and a recorded
`baseline`. The remediation queue becomes phase 5's worklist.

## Next

**Continue** to `phases/2-foundation/SKILL.md`.

If the estate is majority legacy `ROOT_LOCATION`, say so now: migration is a
prerequisite for those apps rather than a detail, and the user may want to
resequence phase 5 earlier.
