# State file

`.streamlit-practice/state.json` at the repo root. It exists because a practice
rollout spans days and several sessions, and because a half-completed phase that
was not recorded gets re-run — which is unsafe for the steps that are not
idempotent (DCM deployment aliases in particular, since a *failed* deploy still
consumes its alias).

Commit it. One operator runs a rollout at a time, and the file is the programme
record: it answers "where did we get to" without re-interrogating the account.

## Schema

```json
{
  "connection": "my_connection",
  "account": "ORG-ACCOUNT",
  "started": "2026-10-21",
  "env_suffix": "_DEV",

  "phases": {
    "1-assess":     { "status": "complete", "completed": "2026-10-21" },
    "2-foundation": { "status": "in_progress", "steps_done": ["git_repo", "roles"] },
    "3-first-app":  { "status": "not_started" },
    "4-govern":     { "status": "not_started" },
    "5-migrate":    { "status": "not_started" },
    "6-harden":     { "status": "not_started" }
  },

  "baseline": {
    "measured": "2026-10-21",
    "total_apps": 91,
    "no_provenance": 81,
    "legacy_root_location": 60,
    "admin_owned": 64,
    "untitled": 58,
    "machine_named": 42,
    "source_models": { "ROOT_LOCATION": 61, "FROM": 25, "WORKSPACE": 3, "UNKNOWN": 1 }
  },

  "objects_created": [
    "GOVERNANCE.APPS.SP_AUDIT_STREAMLIT_APPS",
    "GOVERNANCE.PROJECTS.STREAMLIT_WORK_REPO"
  ],

  "duplicate_decisions": [
    {
      "date": "2026-10-21",
      "proposed": "RETURNS_PERFORMANCE",
      "matched": ["RETAIL.SERVE.SALES_PERFORMANCE"],
      "verdict": "POSSIBLE OVERLAP",
      "decision": "proceed",
      "reason": "Returns is a separate persona and metric set; sales app is revenue-only."
    }
  ],

  "retirement_candidates": [
    { "full_name": "DEMO.PUBLIC.GW52TJ9ZQDCL02EO", "reason": "superseded by RETURNS_PERFORMANCE" }
  ],

  "blocked": [
    { "phase": "2-foundation", "issue": "No CREATE INTEGRATION privilege; needs platform team." }
  ]
}
```

## Rules

**Write after each step, not each phase.** `steps_done` is the resume point.

**`baseline` is written once, by phase 1, and then left alone.** It is the
"before" picture, and the whole value of the rollout is being able to show the
delta. Re-measuring into the same field destroys that. Later audits are rows in
`STREAMLIT_INVENTORY`, which is already a time series.

**Scope the baseline to pre-existing apps.** Counting the apps the rollout
itself deploys flatters the before-picture. Record which names were excluded.

**`blocked` is first-class.** A rollout commonly stalls on a privilege the
operator does not hold. Recording it with the specific missing grant is more
useful than retrying, and it is the handoff to whoever does hold it.

**Never record a phase complete on the strength of a command exiting 0.** Read
the object back first. The failure mode throughout this product area is a
statement that succeeds and does something other than what was intended.
