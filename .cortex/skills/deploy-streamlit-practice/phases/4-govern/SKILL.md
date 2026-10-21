---
name: streamlit-registry-and-certification
description: "Stand up the app registry, the three-tier certification gate, and the catalog portal, then certify the first app."
parent_skill: deploy-streamlit-practice
---

# Phase 4 — Govern

**Rationale:** `streamlit_strategy_v1/05_app_governance_registry.md`;
`00_getting_started.md` steps 2 and 7. Implementation: `catalog/registry.sql`.

The audit records what **is**. The registry records what is **intended** — who
owns it in the business, who gets paged, when it is reviewed, when it retires.
Neither is sufficient alone. Joined, they surface the contradictions that matter:
apps declared production-ready that cannot prove their origin, apps nobody
registered, registered apps that no longer exist.

## Workflow

### Step 1: Agree the tiers and the support boundary

Three tiers, and the gate between them is provenance, not paperwork:

| Tier | Means | Requires |
|---|---|---|
| `EXPLORE` | personal, no support promise | nothing |
| `TEAM` | a team relies on it | named owner, source in Git |
| `CERTIFIED` | the business relies on it | provenance to a commit, functional-role owner, named support group, review date |

**⚠️ Stop.** Get the support boundary written down before the registry exists.
A tier label with no agreed support commitment behind it is decoration, and
`00_getting_started.md` step 2 makes this the deliverable it is.

### Step 2: Deploy the registry

**⚠️ Approval gate.** Creates `APP_REGISTRY`, `SP_CERTIFY_APP`, and the
reconciliation views.

```bash
snow sql -f catalog/registry.sql -c <CONNECTION> --warehouse <WH>
```

### Step 3: Register the app from phase 3

Insert a row with the business facts no amount of introspection can produce:
business owner, technical owner, support group, domain, persona, data
classification, review interval.

Record `SOURCE_PATH` accurately. The duplicate gate's strongest signal — the
same-data check — reads this column, so a vague entry degrades a control you
will rely on for every future app.

Do not populate `APP_URL` by hand. The audit captures `url_id` from
`DESCRIBE STREAMLIT`, and `V_APP_CATALOG` exposes it; a hand-pasted URL rots the
moment an app is recreated.

### Step 4: Certify

```sql
CALL GOVERNANCE.APPS.SP_CERTIFY_APP('<DB>.<SCHEMA>.<APP>', '<certifier>');
```

Two arguments — full name and certifier. The procedure refuses apps that cannot
prove provenance or are admin-owned, which is the behaviour you want. **A
refusal here is the gate working, not a bug.** The two usual causes:

- Admin-owned → the owner role was missing `CREATE STREAMLIT ON SCHEMA`. Fix
  the grant (phase 2) and **recreate** the app as the functional role;
  ownership cannot be transferred.
- No provenance → deployed from a branch path, or by click-ops. Redeploy from a
  commit path.

### Step 5: Reconcile

```sql
SELECT * FROM GOVERNANCE.APPS.V_CERTIFICATION_CONFLICTS;
SELECT * FROM GOVERNANCE.APPS.V_UNREGISTERED_APPS;
SELECT * FROM GOVERNANCE.APPS.V_ORPHANED_REGISTRY_ENTRIES;
SELECT * FROM GOVERNANCE.APPS.V_REVIEW_DUE;
```

`V_UNREGISTERED_APPS` will be long on a real estate — that is the sprawl, and it
is phase 5's input rather than a problem with this phase. The two that must be
empty are `V_CERTIFICATION_CONFLICTS` and `V_ORPHANED_REGISTRY_ENTRIES`: a
conflict means the registry claims something the account contradicts.

### Step 6: Deploy the catalog portal

`catalog/catalog_app/` reads `V_APP_CATALOG` and gives consumers one place to
find certified apps. Without it, certification is invisible to the people it is
meant to serve, and the registry becomes a compliance artifact nobody consults.

### Step 7: Note why the registry is the source of truth

Streamlit *is* taggable via `ALTER STREAMLIT SET TAG`, so certification can be
machine-readable on the object. But DCM's `ATTACH TAG` does not support
STREAMLIT, so a tag cannot be declared in the project and reconciled on every
deployment — it must be applied imperatively and can drift. The table is
authoritative; the tag is a projection. Apply the tag if you want it queryable,
but never read it as truth.

**⚠️ Stop and present.** Report: tiers agreed, registry live, the app's
certification result, and the two reconciliation views that must be empty.

## Output

A registry, a working certification gate, a catalog portal, and one certified
app. Recorded in `state.json`.

## Next

- Legacy or unregistered apps to deal with → `phases/5-migrate/SKILL.md`
- Estate already clean → `phases/6-harden/SKILL.md`
