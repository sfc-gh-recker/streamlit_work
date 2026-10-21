---
name: streamlit-practice-foundation
description: "Build the role model, connect Snowflake to Git, and provision compute — the prerequisites that make a certifiable app possible."
parent_skill: deploy-streamlit-practice
---

# Phase 2 — Foundation

**Rationale:** `streamlit_strategy_v1/02_git_strategy.md`,
`04_rbac_and_ownership.md`, `06_tooling_and_runtimes.md`;
`00_getting_started.md` steps 4–5.

This phase exists because of one product constraint: **Streamlit ownership
cannot be transferred.** Whichever role creates an app owns it forever. Get the
roles wrong here and every app built in phase 3 has to be dropped and recreated.

## Workflow

### Step 1: Decide the role model

Three roles per environment, with distinct jobs:

| Role | Purpose | Must be able to |
|---|---|---|
| `SIS_DEVELOPER{{suffix}}` | humans who write apps | develop in a workspace, read dev data |
| `APP_<domain>_OWNER{{suffix}}` | the role apps *run as* | **create** and run the app |
| `APP_<domain>_VIEWER{{suffix}}` | consumers | `USAGE` on the app |

Ask for the domain name and the environment suffix convention before creating
anything — these end up in object names across every later phase and are
awkward to change afterwards.

### Step 2: Grant the owner role what it needs

**⚠️ Approval gate.** Show every grant.

`demo_app/sources/definitions/access.sql` is the worked example. The grant that
gets missed, every time:

```sql
GRANT CREATE STREAMLIT ON SCHEMA <db>.<schema> TO ROLE APP_<domain>_OWNER;
```

Without it, the owner role can *run* an app but not *create* one — so it can
never own one, so the app stays admin-owned, so certification correctly refuses
it. The app works perfectly throughout, which is why this is found late. The
reference implementation in this repo failed its own certification gate for
exactly this reason.

Also grant the owner role `READ` on the Git repository once step 3 exists, or
`CREATE STREAMLIT FROM` as that role fails on a permission rather than a syntax
error.

### Step 3: Connect Snowflake to Git

**⚠️ Approval gate.** Creating an API integration is usually the step an
operator lacks privileges for. If it fails, record it in `state.json` under
`blocked` with the specific missing grant and stop — that is a cleaner handoff
to the platform team than a partial foundation.

A **public** repository needs no secret and no `ALLOWED_AUTHENTICATION_SECRETS`.
Private needs a fine-grained PAT with Contents:Read. Classic PATs behind org
SAML SSO must be SSO-authorized, or fetches return an opaque 404.

After creating the `GIT REPOSITORY` object, fetch and verify:

```sql
ALTER GIT REPOSITORY <repo> FETCH;
LS @<repo>/branches/main/;
```

`FETCH` is explicit and manual. Nothing re-runs it for you, and a stale repo
makes a correct deployment command ship old code — a failure that looks like a
caching bug and is not.

### Step 4: Provision compute

A warehouse for queries, and a compute pool if any app will use container
runtime. Note which you chose in `state.json`: phase 3 must declare runtime
explicitly, because both `DEFINE STREAMLIT` and `snow streamlit deploy` default
to container and then silently ignore a warehouse-format `environment.yml`.

### Step 5: Verify the foundation holds

The useful test is whether the owner role can actually do its job. Assume
nothing:

```sql
USE ROLE APP_<domain>_OWNER<suffix>;
SHOW GRANTS TO ROLE APP_<domain>_OWNER<suffix>;
-- expect: CREATE STREAMLIT on the serve schema, USAGE on wh/db/schema,
--         READ on the git repository, SELECT on the backing view
```

**⚠️ Stop and present.** List the roles, the grants, the repository object, and
the compute. State explicitly whether the owner role can create a Streamlit —
that single fact determines whether phase 3 produces a certifiable app.

## Output

Roles, grants, a fetched Git repository object, and compute. Recorded in
`state.json` under `objects_created`.

## Next

**Continue** to `phases/3-first-app/SKILL.md`.
