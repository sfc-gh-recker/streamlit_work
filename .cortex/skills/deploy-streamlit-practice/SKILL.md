---
name: deploy-streamlit-practice
description: "Stand up a governed Streamlit-in-Snowflake practice end to end: audit the existing estate, build the role model, wire Git + DCM, deploy the first governed app, add the registry and certification gate, migrate legacy apps, and put a CI gate in. ALSO runs the mandatory duplicate pre-flight before anyone creates a new Streamlit app. Use this skill whenever the user mentions: setting up or rolling out a Streamlit practice, standardizing or governing Streamlit apps, Streamlit sprawl, app registry, app certification, Streamlit estate audit, promoting Streamlit through environments with Git provenance, migrating ROOT_LOCATION apps, onboarding a team onto Streamlit, handing a Streamlit practice to another team, or 'does an app for this already exist'. Triggers: streamlit practice, streamlit governance, streamlit rollout, streamlit sprawl, app registry, certify app, app certification, streamlit estate, streamlit audit, root_location migration, streamlit provenance, duplicate streamlit app, existing app check, streamlit onboarding, productionalize streamlit."
---

# Deploy a Streamlit Practice

Turns the reference material in `streamlit_strategy_v1/` into an executed
rollout. The docs explain *why*; this skill runs the *what*, holds the approval
gates, and records progress so a multi-week programme survives context loss.

**This skill does not restate the docs.** Each phase names the doc that carries
its rationale and loads it only when a decision needs it. If you find yourself
about to explain a design choice at length, read the doc instead.

## Setup

1. **Resolve the connection first.** Nothing below is safe to run against the
   wrong account. Ask which Snowflake connection to use and pass it explicitly
   on every call (`-c <name>`). Do not rely on the active connection: the
   session's active connection and the account holding the practice are
   routinely different, and a silent mismatch creates roles and databases in
   someone else's account.
2. **Read the state file** at `.streamlit-practice/state.json`. If absent, this
   is a new rollout — create it per `references/state.md`.
3. **Load** `references/gotchas.md`. These are verified product behaviours that
   silently do the wrong thing. Most cost an hour each to rediscover.

## Routing

Read `state.json`, then route. Announce the current phase and what it will
change before doing anything.

| Intent | Load |
|---|---|
| New rollout, or "where are we?" | Report state, propose the next incomplete phase |
| Audit the estate / measure sprawl | `phases/1-assess/SKILL.md` |
| Roles, Git repo, warehouses | `phases/2-foundation/SKILL.md` |
| First governed app, DCM, promotion | `phases/3-first-app/SKILL.md` |
| Registry, certification, catalog | `phases/4-govern/SKILL.md` |
| Migrate or retire legacy apps | `phases/5-migrate/SKILL.md` |
| Tests, CI gate, scheduled audit | `phases/6-harden/SKILL.md` |
| **Building a new app / "does this exist?"** | `check-duplicate-app/SKILL.md` |

### Phase order is a real dependency, not a suggestion

```
1 assess ──> 2 foundation ──> 3 first-app ──> 4 govern ──> 6 harden
                                  │               │
                                  │               └──> 5 migrate
                                  │                      (needs the registry to
                                  │                       record what it moved)
                                  └── check-duplicate-app runs INSIDE phase 3,
                                      and again for every app after it
```

Skipping ahead fails late and confusingly rather than early and clearly:

- Phase 3 before 2 produces an app owned by `ACCOUNTADMIN` that can never be
  certified, because Streamlit ownership cannot be transferred after creation.
  The only remedy is to drop and recreate it.
- Phase 5 before 1 means triaging apps you have not measured, so there is no
  way to tell a retirement candidate from a migration candidate.
- Phase 4 before 3 produces a registry with nothing to reconcile against, which
  reads as a clean bill of health.

If the user asks to jump, say which dependency is unmet and what it will cost,
then do as they ask if they confirm.

## Execution rules

**Approval gate before every mutating phase.** Show the exact statements, the
objects they create or change, and the account they will run against. Wait for
explicit approval. Phase 1 is read-only apart from creating the governance
schema and audit objects — say so, since it lowers the bar for starting.

**Record progress after each step, not each phase.** Write to `state.json` as
soon as a step succeeds. A phase that half-completed and was not recorded gets
re-run, and several of these steps are not idempotent — notably DCM deployment
aliases, which a *failed* deploy still consumes.

**Verify, do not assume.** After each mutation, read the object back. `SHOW` and
`DESCRIBE` are cheap; a rollout built on assumed state fails at certification,
which is the most expensive place to find out.

**Report what actually happened.** If a step failed, say so with the error. If
you skipped something, say that. The value of this skill is an operator who can
trust the state file.

## Stopping Points

- ✋ Setup: connection confirmed before any statement runs
- ✋ Before each mutating phase: statements shown and approved
- ✋ Phase 3: duplicate pre-flight returned matches — user decides whether to
  proceed, reuse, or extend the existing app
- ✋ Phase 5: each retirement batch approved by name
- ✋ Any phase where a verification read-back disagrees with what was expected

**Resume rule:** on approval, continue through the phase without re-asking at
every step. Stop again only at the gates above or on an unexpected error.

## Output

A governed Streamlit practice in the target account, and a `state.json`
recording which phases completed, the estate baseline from phase 1, and the
objects created. At the end of each session, report: phase reached, what
changed, what is now enforced, and the single next action.

## Handoff to adjacent skills

This skill owns the *practice*. It deliberately does not own app authoring.

- Writing or debugging the Streamlit app itself → `developing-with-streamlit-in-snowflake`.
  Run `check-duplicate-app` first, then hand off.
- DCM project mechanics beyond what phase 3 needs → `dcm`.
- Snowflake SQL authoring and errors → `sql-author`.

Returning from any of those, come back to the phase that dispatched you and
record the result in `state.json`.
