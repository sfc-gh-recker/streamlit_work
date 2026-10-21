# 00 — Getting Started

This is the day-zero runbook. Documents 01–08 explain *why* the practice is
shaped the way it is; this one is the ordered, executable sequence for standing
it up in an account that has none of it.

Budget half a day for steps 1–6 and treat step 7 onwards as ongoing.

---

## Before you start: privileges you actually need

Check this first. Several steps fail late and unhelpfully if a privilege is
missing, and the error does not always name the privilege.

| Step | Minimum privilege | Why |
|---|---|---|
| Run the audit | A role that can see every database. `ACCOUNTADMIN`, or a custom audit role with object discovery across the account | The audit loops `SHOW STREAMLITS IN ACCOUNT`; apps in databases your role cannot see are silently absent, which looks like a clean estate |
| Create governance objects | `CREATE DATABASE` on the account, or `CREATE SCHEMA` on an existing database | The audit and registry live in `GOVERNANCE.APPS` |
| Create a Git repository object | `CREATE GIT REPOSITORY` on a schema, plus `CREATE INTEGRATION` on the account for the API integration | API integrations are account-level objects |
| Create a DCM project | `CREATE DCM PROJECT ON SCHEMA` | |
| Deploy a DCM project | `OWNERSHIP` on the DCM project | `PLAN` needs this too, not just `DEPLOY` — a dry run requires the same privilege so that it surfaces privilege errors before deployment |
| Create roles / grant | `CREATE ROLE` on the account, `MANAGE GRANTS` | Step 4 |

If you cannot get `ACCOUNTADMIN` for the audit, run it with whatever role you
have and treat the result as a floor rather than a census. Say so when you
present the numbers — an undercount presented as a total is worse than no
number.

---

## Step 1 — Measure the estate

You cannot plan against an estate you have not counted, and the counts decide
how much of the rest of this matters.

```bash
snow sql -f audit/streamlit_inventory.sql
snow sql -q "CALL GOVERNANCE.APPS.SP_AUDIT_STREAMLIT_APPS()"
snow sql -q "SELECT * FROM GOVERNANCE.APPS.V_STREAMLIT_SPRAWL_SUMMARY"
```

Read four numbers off the summary before going further:

| Number | What it decides |
|---|---|
| `legacy_source_model` | How much of step 3 you are signing up for. This is usually the largest single piece of work in the whole programme |
| `no_provenance` | The size of the governance gap you are closing |
| `admin_owned` | Your security exposure. Each one hands the owner's reach to every viewer |
| `not_inspectable` | Apps you cannot even describe. Usually shared or expired-listing apps |

See [05](05_app_governance_registry.md) for what each classification means and
how it is derived.

**Expected failure here:** if `SP_AUDIT_STREAMLIT_APPS` returns a much lower
count than you expect, your role cannot see every database. Check with
`SHOW DATABASES` and compare.

---

## Step 2 — Decide the support boundary, in writing

Do this before any technical work, because it is the thing the rest of the
practice enforces and it is the only step that needs a human decision.

The boundary this practice proposes:

> The platform team supports apps in the catalog. An app is in the catalog when
> it is certified. An app can be certified when it can prove where its code came
> from. Everything else is supported by whoever built it — and the path to
> changing that is a pull request.

Get agreement on that sentence from whoever currently absorbs the support load
and whoever will be told "no" by it. If you skip this, the audit becomes a
report nobody acts on.

See [01 §3](01_dev_workflow_overview.md) for the three-tier model this implies
and [05 §8](05_app_governance_registry.md) for how the boundary is enforced.

---

## Step 3 — Triage the legacy apps

This gates everything else and it is almost always underestimated. Legacy
`ROOT_LOCATION` apps **cannot** use Git, the container runtime, or multi-file
editing, so no Git workflow applies to them until they are migrated.

```sql
SELECT FULL_NAME, OWNER_ROLE, ROOT_LOCATION, AGE_DAYS
FROM GOVERNANCE.APPS.V_STREAMLIT_INVENTORY_LATEST
WHERE IS_LEGACY_SOURCE
ORDER BY AGE_DAYS DESC;
```

Triage into three buckets rather than migrating everything:

| Bucket | Action |
|---|---|
| Business-facing and actively used | Migrate. [07](07_migration_runbook.md) |
| Nobody can name an owner, over a year old | Retire. Most estates are mostly this |
| Someone's scratch app | Leave it in Tier 1. It is not your problem by design |

Retirement is a real outcome, not a cop-out. An estate where nothing is ever
removed only grows.

---

## Step 4 — Stand up the roles

This is the step that unblocks self-service, which is usually the thing users
are actually complaining about.

```bash
# Review and edit first -- it creates account-level roles
snow sql -f demo_app/sources/definitions/access.sql
```

Three roles, and the reasoning behind each is in
[04](04_rbac_and_ownership.md):

| Role | Purpose |
|---|---|
| `SIS_DEVELOPER` | Lets people build and deploy apps **without** admin rights. This is the self-service unblock |
| `APP_<name>_OWNER` | Functional owner of a production app. Never a person |
| `APP_<name>_VIEWER` | Business viewers. Gets no direct data grants — it reads through the app's owner rights |

**Read [04 §2](04_rbac_and_ownership.md) before creating any production app.**
Streamlit ownership **cannot be transferred** after creation. The role that runs
`CREATE STREAMLIT` owns it permanently, so you have to get the owner right the
first time or recreate the app later.

---

## Step 5 — Connect Snowflake to Git

Full detail, including the private-repository path and the SSO gotcha, is in
[02 §4](02_git_strategy.md).

```sql
-- Public repository: no secret, no ALLOWED_AUTHENTICATION_SECRETS
CREATE OR REPLACE API INTEGRATION GIT_API_MYORG
    API_PROVIDER = GIT_HTTPS_API
    API_ALLOWED_PREFIXES = ('https://github.com/my-org')
    ENABLED = TRUE;

CREATE OR REPLACE GIT REPOSITORY GOVERNANCE.PROJECTS.MY_REPO
    API_INTEGRATION = GIT_API_MYORG
    ORIGIN = 'https://github.com/my-org/my-repo';

ALTER GIT REPOSITORY GOVERNANCE.PROJECTS.MY_REPO FETCH;
SHOW GIT BRANCHES IN GOVERNANCE.PROJECTS.MY_REPO;
```

`FETCH` is explicit and manual by design: nothing in the account moves because
someone pushed to a branch. Your CI has to fetch before it deploys.

**Expected failure here:** a private repository behind SAML SSO returns an opaque
404 on `FETCH` if the personal access token has not been SSO-authorized. The
error does not mention SSO. See [02 §4](02_git_strategy.md).

---

## Step 6 — Deploy one real app as the reference

A worked example settles arguments that a document cannot. Use the reference app
in this repo first to prove the mechanics, then do the same for one of your own.

```bash
cd demo_app

# manifest.yml ships MYORG-MYACCOUNT and ANALYTICS_WH placeholders -- set both
snow dcm create --target dev
snow dcm plan   --target dev --save-output
snow dcm deploy --target dev

# DCM is declarative and has no DEFINE for table contents, so data is a hook.
# The suffix is spliced into an identifier: do NOT quote the value.
snow sql -f hooks/seed_data.sql --variable "env_suffix=_DEV" --enable-templating JINJA
```

Then confirm provenance actually landed — this is the whole point, so verify it
rather than assuming:

```sql
CALL GOVERNANCE.APPS.SP_AUDIT_STREAMLIT_APPS();

SELECT APP_NAME, PROVENANCE, DCM_SOURCE_REF,
       SUBSTR(COMMIT_SHA, 1, 12) AS commit_sha, TIER
FROM GOVERNANCE.APPS.V_STREAMLIT_INVENTORY_LATEST
WHERE PROVENANCE <> 'NONE';
```

If `COMMIT_SHA` is null for a DCM-managed app, you deployed from a `branches/`
path. See [03 §6](03_promotion_pipeline.md) — a branch is a moving pointer, and
the shipped commit is then unrecoverable.

See [08](08_testing_and_validation.md) for the full post-deploy validation
sequence.

---

## Step 7 — Stand up the catalog and certification

```bash
snow sql -f catalog/registry.sql
```

This creates the registry, the certification procedure, and the reconciliation
views that catch the registry and the account disagreeing. [05](05_app_governance_registry.md)
explains each.

Then deploy the catalog portal so users have somewhere to *find* approved apps.
A curated portal is what makes the tier model feel like a service rather than a
restriction:

```bash
cd catalog/catalog_app
snow streamlit deploy --replace    # fine for the portal; see note below
```

`--replace` is create-or-replace and **drops the app's grants** — verified. It is
acceptable for the portal while you are standing it up, and not acceptable for a
production app with viewers. Use DCM for those. See
[03](03_promotion_pipeline.md).

---

## Step 8 — Make the audit recurring

A one-off audit is a slide. A recurring one is a control.

```sql
ALTER TASK GOVERNANCE.APPS.TSK_AUDIT_STREAMLIT_APPS RESUME;
```

The task ships suspended. Point its findings somewhere a human reads weekly —
the remediation queue is the useful view:

```sql
SELECT * FROM GOVERNANCE.APPS.V_STREAMLIT_REMEDIATION_QUEUE LIMIT 20;
```

---

## Step 9 — Onboard the first team

The practice is not real until someone other than its author uses it. A
reasonable first-team sequence:

1. Grant them `SIS_DEVELOPER`. They can now build without filing a ticket.
2. Point them at Tier 1: build whatever you like in your own workspace, nobody
   will stop you and nobody will support it.
3. When one app matters, they open a PR to move it to Tier 2. The PR is the
   promotion mechanism — see [02 §7](02_git_strategy.md).
4. When it is business-critical, it goes through DCM to Tier 3 and into the
   catalog.

The deliberate property here is that each step is **self-service and visible**.
Nobody has to argue their app is important; they have to put it in Git.

---

## Where to go next

| You want to | Read |
|---|---|
| Understand the model and the tiers | [01 — Development Workflow Overview](01_dev_workflow_overview.md) |
| Set up repos, branches, PR checks | [02 — Git Strategy](02_git_strategy.md) |
| Build the dev → test → prod pipeline | [03 — Promotion Pipeline](03_promotion_pipeline.md) |
| Get ownership and permissions right | [04 — RBAC and Ownership](04_rbac_and_ownership.md) |
| Run the audit, registry, certification | [05 — App Governance and Registry](05_app_governance_registry.md) |
| Choose runtimes, pin versions, avoid the session-state bugs | [06 — Tooling and Runtimes](06_tooling_and_runtimes.md) |
| Migrate legacy `ROOT_LOCATION` apps | [07 — Migration Runbook](07_migration_runbook.md) |
| Test and validate before and after deploy | [08 — Testing and Validation](08_testing_and_validation.md) |

---

Next: [01 — Development Workflow Overview](01_dev_workflow_overview.md)
