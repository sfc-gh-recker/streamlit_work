---
name: check-duplicate-app
description: "Pre-flight check that no equivalent Streamlit app already exists, in the Snowflake account or in the repo, before a new one is built."
parent_skill: deploy-streamlit-practice
---

# Duplicate App Pre-flight

## When to Load

- `deploy-streamlit-practice` phase 3, before scaffolding the first app
- Every subsequent new app, indefinitely — this is the gate that keeps the
  estate from re-sprawling after the rollout
- Directly, when someone asks whether an app for some purpose already exists

## Why this gate exists

Nobody sets out to build the third returns dashboard. They build the first one
because they cannot see the other two. Estates grow by accretion, and the only
cheap moment to intervene is before the app is created — afterwards it has
users, and consolidating it becomes a negotiation rather than a decision.

Name matching alone is not enough in a sprawling estate, for a reason worth
knowing: a large share of apps created through Snowsight's workspace preview
carry machine-generated names like `ST4A27C91BEA...` with the title `Untitled`.
Measured on a 91-app estate, 42 were machine-named. Those are invisible to name
search, so the check reports its own blind spot rather than implying the search
was exhaustive.

## Workflow

### Step 1: Establish what is being built

**Goal:** three inputs, because each drives a different signal.

Ask for, or infer from the conversation:

| Input | Used for |
|---|---|
| Proposed app name (identifier form) | name similarity |
| Proposed title / one-line purpose | title and token similarity |
| Backing view or table, if decided | same-data match — the highest-value signal |

If the backing data is not yet decided, pass `data_source=` empty and say that
the strongest signal was unavailable. Do not guess a source: a wrong one
produces a confident clean result, which is worse than an acknowledged gap.

### Step 2: Search the account

```bash
snow sql -f audit/duplicate_check.sql --enable-templating JINJA \
  -c <CONNECTION> \
  --variable "app_name=RETURNS_PERFORMANCE" \
  --variable "app_title=Returns Performance" \
  --variable "data_source=RETAIL.SERVE.V_RETURNS"
```

Pass identifier fragments **unquoted**. `snow sql --variable` does not strip
quotes, so `--variable "app_name='X'"` renders the quote characters into the
SQL and the match silently finds nothing.

The script emits three result sets:

1. **Ranked matches** — `NEAR-IDENTICAL`, `LIKELY DUPLICATE`, or
   `POSSIBLE OVERLAP`. Rows below those thresholds are suppressed rather than
   shown, so anything returned is worth reading.
2. **Same-data matches** from the registry. Degrades to a skip note on a
   greenfield account where the registry is not yet deployed — that is expected
   in phase 3, not an error.
3. **Coverage** — how many apps were searched and how many were unmatchable by
   name.

### Step 3: Search the repo

An app can exist in source before it exists in the account, and vice versa.
Check both:

```bash
ls demo_app/streamlit/
grep -ril "<backing view or table>" --include=*.py .
```

The grep is the useful half. Two apps querying the same view are near-certainly
redundant even when their names share nothing.

### Step 4: Report and decide

**⚠️ MANDATORY STOPPING POINT** when anything returned at
`POSSIBLE OVERLAP` or above, or when the repo grep hit.

Present a table of: full name, title, owner, tier and certification if known,
what it matched on, and whether it is in the account, the repo, or both. Then
state the coverage honestly, e.g. "searched 91 apps; 42 are machine-named and
could not be matched on name."

Ask which applies:

| Choice | Action |
|---|---|
| **Reuse the existing app** | Stop. Record nothing new. If it needs a change, hand off to `developing-with-streamlit-in-snowflake`. |
| **Extend the existing app** | Stop creating. Hand off to the authoring skill against that app's source path. |
| **Proceed — genuinely different** | Record the decision and the reason in `state.json` under `duplicate_decisions`, then continue. |
| **Proceed — consolidate later** | Record it, and add the superseded app to `state.json` under `retirement_candidates` so phase 5 picks it up. |

Recording the reason matters more than it looks. It is the difference between an
estate with four sales dashboards and an estate with four sales dashboards and a
written answer for why.

**If nothing matched:** say what was searched and what the coverage was, then
continue without a stop. A clean result stated as "no name collision across 91
apps, 42 unmatchable by name" is accurate; "no duplicate exists" is not.

## Output

A duplicate verdict, a recorded decision in `state.json` when the user chose to
proceed despite matches, and either a handoff to the authoring skill or
clearance to continue.

## Next

- Called from phase 3 → return to `phases/3-first-app/SKILL.md`
- Called directly → stop here, unless the user wants the app built, in which
  case continue to `phases/3-first-app/SKILL.md`
