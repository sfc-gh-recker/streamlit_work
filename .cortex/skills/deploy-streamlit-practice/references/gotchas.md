# Verified traps

Each of these was measured, not inferred. They share a failure mode: the
command succeeds and does the wrong thing, so there is nothing to debug until
much later. Phase references point at `streamlit_strategy_v1/` for rationale.

## The mechanism inversion — the most expensive one

The two deploy mechanisms have **opposite** Git path requirements. Generalizing
one to the other either hard-fails or silently destroys auditability.

| Mechanism | `branches/<br>/` | `commits/<sha>/` | Commit recorded where |
|---|---|---|---|
| `CREATE STREAMLIT FROM` | works | works | resolved and frozen on the version |
| `ALTER STREAMLIT ADD VERSION FROM` | works | **rejected** | frozen per version |
| `EXECUTE DCM PROJECT ... FROM` | works | works | `source_file_path` string **only** |

- `ADD VERSION FROM '@repo/commits/<sha>/...'` fails with
  `Invalid git branch path` at any depth, despite the docs listing a commit URI
  form. Use `branches/` — the resolved SHA is captured anyway, so nothing is
  lost.
- DCM is the inverse: `branches/` is *accepted* but records a moving pointer, so
  you can never establish which commit shipped. **Deploy DCM from
  `commits/<sha>/`.**
- `SHOW DEPLOYMENTS IN DCM PROJECT`.`git_commit_hash` **never populates**, even
  deploying from a commit path. The only DCM-side Git evidence is the literal
  path string. Extract it:
  `REGEXP_SUBSTR(source_file_path, '/commits/([0-9a-f]{40})/', 1, 1, 'e', 1)`

## Provenance lives in three different places

An audit keyed only on the app object's `git_commit_hash` reports a fully
CI/CD-governed DCM app as ungoverned — a false positive on your *best* app. The
gate must accept **either** a commit hash on the object **or** membership in a
DCM project (`SHOW ENTITIES IN DCM PROJECT`, filtered to
`object_type='STREAMLIT'`). The cross-reference is mandatory, not an
optimization.

Write the gate as `WHERE provenance = 'NONE'`, never
`WHERE git_commit_hash IS NULL`.

## Ownership is permanent

Streamlit ownership **cannot be transferred**. There is no
`ALTER STREAMLIT SET OWNER`, `GRANT OWNERSHIP` does not list STREAMLIT, and DCM
rejects it outright. The deploying role owns it forever.

Consequences that shape the whole rollout:

- An app created by `ACCOUNTADMIN` can never be certified. It must be dropped
  and recreated as the functional role. This is why phase 2 precedes phase 3.
- `CREATE STREAMLIT ON SCHEMA` is the grant everyone forgets. A functional owner
  role privileged only to *run* an app cannot *create* one, so it can never own
  one. The reference implementation failed its own certification gate for
  exactly this reason.
- Split DCM into two projects: infra (broad DDL role) and app (least-privilege
  functional role), because the app project's deploying role becomes the app
  owner.

## Four source models, and a detection bug waiting to happen

`DESCRIBE STREAMLIT` returns a **different column set** per model. Wrap it in
`OBJECT_CONSTRUCT(*)` and read VARIANT keys so a missing key yields NULL rather
than a compile error.

| Signal | Model |
|---|---|
| `root_location` present | ROOT_LOCATION (legacy, 13 cols) |
| `source_location LIKE 'snow://workspace/%'` | WORKSPACE (`versions/head` is a moving pointer) |
| version columns exist | FROM (modern, 25 cols) |
| none of the above | UNKNOWN (e.g. un-describable shared app) |

**Do not detect FROM via `live_version_location_uri` being set.** That column
stays empty until a user first *opens* the app, so freshly deployed Git apps get
misreported as UNKNOWN and drop silently out of the worklist. Key on
`default_version_name IS NOT NULL OR ARRAY_CONTAINS('live_version_location_uri'::VARIANT, OBJECT_KEYS(d))`.
`ARRAY_CONTAINS` is a function, not an infix operator.

There is no `ACCOUNT_USAGE.STREAMLITS` view, and `GRANTS_TO_ROLES` returns zero
rows for Streamlit. Inventory must loop `SHOW` + `DESCRIBE`.

## Migration (phase 5)

- **Cannot convert in place.** `ADD VERSION FROM` on a legacy app fails
  `Attached stage not exists.` — there is no embedded versioned stage.
- `CREATE OR REPLACE STREAMLIT` **preserves `url_id`**, so links and bookmarks
  survive. Counter-intuitive, and it removes the main objection to migrating.
- `CREATE OR REPLACE STREAMLIT` **silently drops privilege grants.** The owner
  still works; every viewer breaks. Capture first and replay from
  `SHOW GRANTS`, filtering `"privilege" <> 'OWNERSHIP'`.
- Old `ROOT_LOCATION` stage files are not removed — orphaned storage, and your
  rollback. `REMOVE @stage/path/` only after a few days.
- Run the recreate **as the intended owner role**, since ownership is permanent.

## DCM

- **Jinja variables do not reach Streamlit Python files.** Templating a database
  name ships a prod app silently reading dev data. Use `CURRENT_DATABASE()`.
- **Explicit asset paths flatten directories.** The literal prefix before the
  first wildcard is stripped, so `'app/utils/config.py'` lands as `config.py`
  and imports break. Only `'app/**/*'` preserves structure. Verify with
  `find out/rendered/assets -type f` after `--save-output`.
- `**` globs sweep in `__pycache__`. Set `PYTHONDONTWRITEBYTECODE=1` and clean
  before deploying; globs have no negation.
- **Cannot rename or insert a column mid-list.** Tables fail with
  `column add before end of column list`; views are stricter and refuse
  reordering. An out-of-band `ALTER TABLE RENAME COLUMN` fixes the table but not
  the view. When both change, `PURGE` and rebuild is the only clean path.
  Appending at the end is fine.
- **Deployment aliases must be unique, and a failed deploy still consumes its
  alias.** Retrying the same alias gives `already exists with alias`.
- **No `DEFINE` for table contents.** Data loading is imperative and belongs in
  a post-deploy hook, or the reference app deploys clean and renders empty.
- `ATTACH TAG` does not support STREAMLIT. Streamlit *is* taggable via
  `ALTER STREAMLIT SET TAG`, just not declaratively — which is why the registry
  table is the source of truth and the tag is a projection of it.
- Each environment needs its **own** DCM project object; one object holds one
  configuration at a time, so deploying config B drops config A's objects.
- `snow dcm plan` takes `--from <dir>` and `--target`, not `--project-path`. Run
  `snow dcm create --target dev` before the first plan. `PLAN` requires the same
  OWNERSHIP as `DEPLOY`.

## Runtime

- `DEFINE STREAMLIT` and `snow streamlit deploy` both default to **container**
  runtime, which silently ignores a warehouse-format `environment.yml`. Declare
  `COMPUTE_POOL` / `RUNTIME_NAME` explicitly.
- `user_packages` is empty for container-runtime apps, so pins cannot be
  verified from metadata. Report `st.__version__` from inside the app.
- Range pins such as `streamlit>=1.39.0` silently do not apply on warehouse
  runtime (see https://docs.snowflake.com/en/developer-guide/streamlit/app-development/dependency-management). Use exact pins.
- `snow streamlit deploy --replace` is create-or-replace and can drop grants.
  Unsafe for production — use DCM plan/deploy.
- Legacy `ROOT_LOCATION` apps cannot use Git integration, container runtime, or
  multi-file editing. In a typical estate they are the majority, which makes
  migration a prerequisite rather than a detail.

## CLI and SQL

- **`snow sql --variable` does not strip quotes.** `--variable "suffix='_DEV'"`
  renders the quotes into the SQL. Pass identifier fragments unquoted, with
  `--enable-templating JINJA`.
- Snowflake regex rejects the inline `(?i)` flag. Use `REGEXP_LIKE(c, p, 'i')`.
- `RESULT_SCAN(LAST_QUERY_ID())` refers to the *immediately* preceding
  statement. Needing a result twice means capturing the id into a variable
  first.
- A public Git repository needs no secret and no
  `ALLOWED_AUTHENTICATION_SECRETS`. Private needs a fine-grained PAT with
  Contents:Read; classic PATs behind org SAML SSO must be SSO-authorized or
  fetches 404 opaquely.
- `FETCH` on a Git repository is explicit and manual. A stale repo makes a
  correct deployment command ship old code.

## Session state in the app itself

Four rules that prevent the filter-state bug class:

1. Seed defaults **once** with `setdefault`, before any widget renders; deepcopy
   mutables.
2. A keyed widget passes no `index=`, `value=`, or `default=` — one source of
   truth.
3. Resets are `on_click` callbacks, never a pending flag plus `st.rerun()`; a
   mid-script rerun truncates before later widgets re-register.
4. Never assign to a widget-bound key after that widget rendered on the same
   run. Modern Streamlit raises; older deployed runtimes instead surface a stale
   value on the next unrelated rerun.
