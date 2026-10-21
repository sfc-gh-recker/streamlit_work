---
name: harden-streamlit-practice
description: "Make the practice self-sustaining: tests, a CI provenance gate, the recurring audit, and onboarding the first team."
parent_skill: deploy-streamlit-practice
---

# Phase 6 — Harden

**Rationale:** `streamlit_strategy_v1/08_testing_and_validation.md`;
`00_getting_started.md` steps 8–9.

Everything so far was done by an operator. This phase makes it hold without one.
A practice that depends on someone remembering to run the audit is a practice
with an expiry date.

## Workflow

### Step 1: Put the tests in

`08_testing_and_validation.md` defines six layers. Start with the two that catch
real defects rather than the ones that are easy to write:

- **Static checks** on the app source — that every column the app selects exists
  in the view it selects from. Make the check alias-aware: `AS` aliases in the
  app's own SQL are not view columns, and a naive version reports them as
  missing. Use word-boundary regex for short tokens, or a token like `NFL`
  matches inside `V_CERTIFICATION_CO**NFL**ICTS`.
- **Invariant assertions** that encode the business rules a rename or refactor
  silently breaks — that an unsuffixed database is production, that a rate is
  weighted by the unit it claims to be weighted by.

Both of those found genuine defects in the reference implementation. Layers that
only restate the schema find nothing.

### Step 2: Gate the pipeline on provenance

The gate is the whole point. Write it as:

```sql
-- correct
WHERE provenance = 'NONE'
```

Never as `WHERE git_commit_hash IS NULL`, which reproduces the exact false
positive the audit exists to avoid: it flags a fully governed DCM app as
ungoverned. Provenance lives in three different places — see
`references/gotchas.md`.

Assertions worth failing a build on:

| Assertion | Must be |
|---|---|
| certified apps with no provenance | 0 |
| certified apps deployed from a moving branch pointer | 0 |
| certified apps with no recoverable commit | 0 |
| orphaned registry rows | 0 |
| registry/account certification conflicts | 0 |

### Step 3: Make the audit recurring

```sql
CREATE OR REPLACE TASK GOVERNANCE.APPS.TSK_AUDIT_STREAMLIT_APPS
    WAREHOUSE = <WH>
    SCHEDULE  = 'USING CRON 0 6 * * 1 UTC'
AS CALL GOVERNANCE.APPS.SP_AUDIT_STREAMLIT_APPS();

ALTER TASK GOVERNANCE.APPS.TSK_AUDIT_STREAMLIT_APPS RESUME;
```

**Verify it is resumed**, not merely created. A suspended task is the default
state and produces exactly the same silence as a working one.

```sql
SHOW TASKS LIKE 'TSK_AUDIT%' IN SCHEMA GOVERNANCE.APPS;   -- state = started
```

Weekly is enough. `STREAMLIT_INVENTORY` accumulates snapshots, so the series is
what makes the delta against phase 1's baseline demonstrable.

### Step 4: Wire CI

`08_testing_and_validation.md` carries a worked CI configuration. The shape that
matters: on pull request run static checks and `snow dcm plan`; on merge deploy
from the commit SHA, then assert provenance.

One caveat to carry rather than paper over: `snow streamlit execute` returns
`001022 (0A000): Operation not supported.` on container runtime. Whether
warehouse runtime behaves differently is **untested** — no warehouse-runtime app
was available. Treat an automated smoke test as unproven rather than building a
gate on it.

### Step 5: Onboard the first team

The transferable artifact, and the real test of the practice.

Walk one team through: clone, `check-duplicate-app`, author, plan, deploy from a
commit, register, certify. Then hand them `streamlit_strategy_v1/README.md` —
its reading-paths table routes a developer, a reviewer and a platform owner
differently, which matters because they need different subsets.

Watch for the two things that do not survive a handover unless stated:

- **`CREATE STREAMLIT ON SCHEMA`** is the grant a new domain's owner role gets
  missed. It is the single most likely reason their first app cannot be
  certified.
- **The duplicate gate** has to become habit before the estate grows again. It
  is the only control here that prevents sprawl rather than measuring it.

**⚠️ Stop and present.** Report: which assertions are enforced and where, that
the audit task is `started`, and whether a team has completed the loop
unaided — which is the actual definition of done for this phase.

## Output

Tests, an enforced provenance gate, a running scheduled audit, and one team
operating the practice without the operator. The rollout is complete.

## Next

Nothing. Report the final state: the phase 1 baseline against the current audit,
what is now enforced, and what the user chose not to do.

Two items commonly left open, worth naming explicitly rather than leaving
implied:

- The **two-DCM-project split** (`04_rbac_and_ownership.md`) if phase 3 proved
  ownership with a single `CREATE STREAMLIT` instead.
- Remaining **unregistered apps** from phase 5, with a count.
