# 06 — Tooling and Runtimes

## 1. Where to author

**Workspaces** are the current direction, not a folder hierarchy inside the deployed object. A workspace gives file-based development, private editing, Git-backed collaboration, and a clean separation between the *development* app (private to you) and the *deployed* app (a schema object owned by a role).

| Surface | Use for | Tier |
|---|---|---|
| **Workspace, personal** | Exploration, single-file experiments | 1 |
| **Workspace, Git-backed** | Team development with source control | 2 |
| **Workspace, shared** | Collaboration without Git — anyone can run, only the owner role can deploy | 2 |
| **Local IDE + `snow` CLI** | Mature engineering teams, CI/CD | 2–3 |
| **Snowsight direct edit** | Emergency fixes only, then backport to Git | — |

That last row deserves a caveat: editing in Snowsight breaks the link between the deployed object and the repository. The object no longer matches any commit, so it silently drops out of certification. If you must do it, open a PR the same day.

### On folders and sprawl

The instinct when facing 81 apps is to ask for folders. Folders would not have prevented this — 58 of those apps were never even named. Sprawl is a **lifecycle** problem, not a filing problem, and the answer is the tier model plus the audit plus a retirement step.

The internal design work deliberately avoids forcing every small app into a rigid structure, and that is correct: a single-file experiment is a legitimate Tier 1 use case and adding ceremony to it would just push people back to spreadsheets. Organization comes from four things:

1. Workspaces for authoring
2. Git repositories for durable source control
3. Database and schema boundaries for production structure
4. The registry, plus naming conventions like `DOMAIN_APP_PURPOSE_ENV`, for discovery

## 2. Runtime choice

| | Warehouse runtime | Container runtime |
|---|---|---|
| Packages | Snowflake Anaconda channel | Any PyPI package |
| Dependency file | `environment.yml` | `requirements.txt` / `pyproject.toml` |
| Compute | Query warehouse | **Compute pool**, billed separately |
| Runs as a stored procedure | **yes** — inherits those restrictions | no |
| `DESCRIBE` / `SHOW` / `LIST` in app | restricted | available |
| Restricted caller's rights | no | yes |
| Requires `FROM` source model | no | **yes** |
| External network access | — | needs an external access integration |

**Choose container runtime when** you need a non-Anaconda package, per-viewer caller's rights, or `SHOW`-style introspection (admin and catalog apps).

**Choose warehouse runtime when** the Anaconda channel covers you and you would rather not run a compute pool.

Legacy `ROOT_LOCATION` apps **cannot** use the container runtime at all — another reason the migration in [02](02_git_strategy.md) gates so much.

### `DEFINE STREAMLIT` defaults to container runtime

Measured: omitting `COMPUTE_POOL` and `RUNTIME_NAME` from `DEFINE STREAMLIT` still produced a container-runtime app.

That silently invalidated an `environment.yml` shipped with the app, because `environment.yml` is the *warehouse*-runtime format. Nothing failed. The file was present, correct, committed, and reviewed — and had no effect.

**Declare the runtime explicitly** so the dependency file format is a deliberate choice rather than a consequence of a default:

```sql
DEFINE STREAMLIT ...
    COMPUTE_POOL = SYSTEM_COMPUTE_POOL_CPU
    RUNTIME_NAME = 'SYSTEM$ST_CONTAINER_RUNTIME_PY3_11'
```

## 3. Dependency pinning

**Pin exact versions. Never ranges.**

Range pins such as `streamlit>=1.39.0` do **not** reliably take effect on the warehouse runtime (SNOW-3601653). The app runs on whatever the runtime picks, and that can change with no code edit and no deployment.

Measured on the audited account: **81 of 81 apps have no exact pin.** Every one can change behaviour underneath its owner.

This is not hypothetical. The filter-state bug investigated in September reproduced on deployed SiS but not on local Streamlit 1.50 — because the deployed runtime version was not what the developer assumed. Time spent diagnosing a version mismatch as a logic bug is the real cost of an unpinned dependency.

```
# container runtime — requirements.txt
streamlit==1.52.2
pandas==2.2.3
plotly==5.24.1
```

```yaml
# warehouse runtime — environment.yml
name: sf_env
channels:
  - snowflake
dependencies:
  - streamlit=1.52.2
```

Notes:

- The warehouse runtime supported list tops out at **1.52.2**. Anything at or above 1.54 implies the container runtime.
- `CREATE STREAMLIT` via **SQL defaults to Streamlit 1.22.0** for backward compatibility, while Snowsight defaults to latest. An app created by SQL may be far older than assumed.
- The warehouse runtime does **not** ignore `environment.yml` when a `pyproject.toml` is also present. Do not ship both.

### Verifying the pin took effect

**`user_packages` from `DESCRIBE STREAMLIT` does not work for container-runtime apps.** Measured: it is populated for warehouse-runtime apps but comes back **empty** for container-runtime apps even with a correct `requirements.txt`. Reading it would tell you the pin failed when it had not.

Report the resolved version from inside the app instead — the only self-evidencing check, since what the app reports is by definition what it is running:

```python
st.caption(f"Streamlit runtime: `{st.__version__}`")
```

And cross-check which dependency format is even being read:

```sql
DESCRIBE STREAMLIT <db>.<schema>.<app>;
-- runtime_name empty                       -> warehouse, environment.yml
-- runtime_name SYSTEM$ST_CONTAINER_RUNTIME -> container, requirements.txt
```

## 4. Session state: the four rules

These come from the September filter-state investigation, where a deselected filter reappeared after switching grids. Each rule maps to a failure that was observed on a deployed app, not a theoretical concern.

**Rule 1 — seed defaults once, before any widget.**

```python
FILTER_DEFAULTS = {"flt_leagues": [], "flt_channels": []}
for key, default in FILTER_DEFAULTS.items():
    st.session_state.setdefault(
        key, list(default) if isinstance(default, list) else default
    )
```

One authoritative dict. A second, disagreeing copy elsewhere is its own bug class — the original app had exactly that, with conflicting reset values.

**Rule 2 — a keyed widget passes no `index=` / `value=` / `default=`.**

```python
st.multiselect("League", options=leagues, key="flt_leagues")     # correct
st.multiselect("League", options=leagues, default=[], key="flt_leagues")  # wrong
```

With a `key`, `session_state` is the source of truth and the literal is only an initial default. Supplying both makes them compete.

**Rule 3 — resets are `on_click` callbacks, never "pending flag + `st.rerun()`".**

```python
def _clear_filters():
    for k, v in FILTER_DEFAULTS.items():
        st.session_state[k] = list(v) if isinstance(v, list) else v

st.button("Clear filters", on_click=_clear_filters)
```

Callbacks run **before** the script re-executes, so widgets are rebuilt from the reset value. A mid-script `st.rerun()` truncates the run before later widgets re-register, which is how the original app also lost its grid selection on every filter clear.

**Rule 4 — never assign to a widget-bound key after that widget has rendered on the same run.**

Current Streamlit raises `StreamlitAPIException`. Older deployed runtimes instead produce a stale value that reappears on the next unrelated rerun — much harder to diagnose, and exactly what happened. Snowflake Support case 01322560 classifies this as expected Streamlit execution semantics, not a platform defect.

## 5. Query hygiene

```python
# Parameterize. Always.
df = conn.query(
    "SELECT * FROM v WHERE region = :1 AND d BETWEEN :2 AND :3",
    params=[region, start, end], ttl=600,
)
```

Even when a value comes from a selectbox the app populated itself. String interpolation is how injection arrives later, when someone swaps that widget for a text input.

Cache deliberately — filter domains change far less often than measures:

```python
@st.cache_data(ttl=3600)   # domain values
@st.cache_data(ttl=600)    # measures
```

Read filter values from `st.session_state`, not from widget return values, so behaviour is identical whether the run was triggered by a widget, a callback, or an unrelated rerun.

## 6. Observability

```bash
snow streamlit logs MY_APP --follow
```

This is the direct answer to "apps break and we find out from the business". Combine with an event table for production apps so errors are queryable and alertable rather than discovered:

```sql
ALTER STREAMLIT FANATICS_MERCH.SERVE.MERCH_PERFORMANCE
  SET LOG_LEVEL = 'INFO';
```

| Signal | Source |
|---|---|
| App errors, tracebacks | Event table, `snow streamlit logs` |
| Query cost and performance | `ACCOUNT_USAGE.QUERY_HISTORY` |
| Who is using it | `ACCOUNT_USAGE.ACCESS_HISTORY` |
| Governance drift | `V_STREAMLIT_SPRAWL_SUMMARY` over time |
| Deployment history | `SHOW DEPLOYMENTS IN DCM PROJECT` |

Usage data has a second purpose: an app with no queries in ninety days is a retirement candidate, and that is a far easier conversation with evidence.

## 7. CLI reference

```bash
snow --version                        # 3.14.0+ for container runtime

snow streamlit list
snow streamlit describe MY_APP
snow streamlit get-url MY_APP
snow streamlit logs MY_APP --follow
snow streamlit share MY_APP --to-role ANALYST

snow dcm create --target dev
snow dcm plan   --target dev --save-output
snow dcm deploy --target dev --alias "$(git rev-parse --short HEAD)"
snow dcm list-deployments GOVERNANCE.PROJECTS.MERCH_PERFORMANCE_DEV

snow git fetch MY_DB.MY_SCHEMA.MY_REPO
snow git list-branches MY_DB.MY_SCHEMA.MY_REPO
```

Avoid `snow streamlit deploy --replace` for production apps — it is a create-or-replace that can drop grants. Use DCM.

## 8. Local development

```bash
uv sync
PYTHONDONTWRITEBYTECODE=1 uv run streamlit run streamlit_app.py
```

`PYTHONDONTWRITEBYTECODE=1` matters more than it looks: without it, `__pycache__` directories get swept into the DCM asset glob and deployed. See [03](03_promotion_pipeline.md).

`.streamlit/secrets.toml` for local connection config, never committed. The deployed app needs none of it.

## 9. Choosing Streamlit at all

| Need | Reach for |
|---|---|
| Python dashboard, data app, internal tool | **Streamlit in Snowflake** |
| Lightweight tabular report | Dashboards / HTML report |
| Conversational analytics | Cortex Agents / Snowflake Intelligence |
| Full custom web stack, any npm package | Snowflake App Runtime |
| Distributing an app to other accounts | Native App Framework |

Worth naming because the confusion is common: an agent and a Streamlit app are not competing options. An agent answers questions conversationally; a Streamlit app shows data directly. Users who reject a chat interface and want to *see* their numbers are asking for the latter, and telling them to converse with an agent instead will not land.

---

Previous: [05 — App Governance and Registry](05_app_governance_registry.md) · Back to [README](README.md)
