# 08 — Testing and Validation

The single most useful sentence in this document set is in
[03 §6](03_promotion_pipeline.md):

> `PLAN` does not test whether the app *runs*. It only validates that the object
> can be created.

That gap is where production incidents come from. A DCM `PLAN` and `DEPLOY` both
succeed on an app whose first line is `import plotly` when `plotly` is not
installed. The object is created, the deployment is recorded, CI goes green, and
the app shows a traceback to the first person who opens it.

This document is the layered check that closes the gap. Each layer catches a
different class of failure and costs a different amount, so run them in order.

| Layer | Catches | Where it runs | Cost |
|---|---|---|---|
| 1. Static | Syntax errors, broken imports, bad SQL | Pre-commit, CI | Seconds |
| 2. Unit | Wrong aggregation, division by zero, bad filter logic | CI | Seconds |
| 3. Plan | Invalid DDL, missing privileges, bad templating | CI on PR | A minute |
| 4. Deploy-time | Does the object exist and read correctly | CI after deploy | A minute |
| 5. Smoke | **Does the app actually render** | After deploy | Manual or scripted |
| 6. Provenance | Is the thing you deployed traceable | CI after deploy | Seconds |

---

## Layer 1 — Static checks

Cheapest and catches the most common failure, which is a typo.

```bash
# Syntax. Use ast.parse rather than py_compile: py_compile writes bytecode,
# and a ** asset glob will happily deploy __pycache__ into your app.
python -c "
import ast, pathlib, sys
bad = 0
for p in pathlib.Path('demo_app/streamlit').rglob('*.py'):
    try:
        ast.parse(p.read_text())
    except SyntaxError as e:
        print(f'FAIL {p}: {e}'); bad = 1
sys.exit(bad)
"
```

Set `PYTHONDONTWRITEBYTECODE=1` in CI regardless, as a second line of defence.

**Validate the SQL without running it.** Snowflake can compile a statement and
tell you whether it is valid without executing it, which is exactly what you
want for a view definition in a PR:

```bash
# fails the build on a SQL compilation error, touches no data
snow sql -q "EXPLAIN SELECT * FROM RETAIL_DEMO_DEV.SERVE.V_SALES_PERFORMANCE"
```

**Check the dependency spec matches the runtime.** This is the `plotly` failure
above, and it is worth an explicit check because the mismatch is silent:

| Runtime | Correct file | What happens with the wrong one |
|---|---|---|
| Container (`SYSTEM$ST_CONTAINER_RUNTIME_PY3_11`) | `requirements.txt` | A shipped `environment.yml` is **silently ignored** |
| Warehouse (`SYSTEM$WAREHOUSE_RUNTIME`) | `environment.yml` | A shipped `requirements.txt` is ignored |

```bash
# container-runtime app must not ship environment.yml
test ! -f demo_app/streamlit/sales_performance/environment.yml \
  || { echo "FAIL: environment.yml is ignored on the container runtime"; exit 1; }

# and must pin exactly -- range pins silently do not apply (see https://docs.snowflake.com/en/developer-guide/streamlit/app-development/dependency-management)
grep -qE '^streamlit==[0-9]' demo_app/streamlit/sales_performance/requirements.txt \
  || { echo "FAIL: streamlit is not pinned exactly"; exit 1; }
```

---

## Layer 2 — Unit tests

The testable part of a Streamlit app is the part that is not Streamlit. This is
the main argument for the `utils/` split in the reference app: `data.py` and
`config.py` contain the logic worth testing, and `streamlit_app.py` contains the
rendering that is not.

Pure functions test normally:

```python
# tests/test_config.py
from utils.config import resolve_environment

class FakeConn:
    def __init__(self, db): self._db = db
    def query(self, sql, **kw):
        import pandas as pd
        return pd.DataFrame({"DB": [self._db]})

def test_dev_database_resolves_to_dev():
    env = resolve_environment(FakeConn("RETAIL_DEMO_DEV"))
    assert env["env_label"] == "DEV"
    assert env["is_prod"] is False
    assert env["serve_view"] == "RETAIL_DEMO_DEV.SERVE.V_SALES_PERFORMANCE"

def test_unsuffixed_database_is_prod():
    # the suffix convention IS the environment contract -- assert it
    env = resolve_environment(FakeConn("RETAIL_DEMO"))
    assert env["env_label"] == "PROD"
    assert env["is_prod"] is True
```

That second test is worth more than it looks. `resolve_environment` is what
stops a PROD app reading DEV data, because DCM Jinja variables do not reach
Python files — see [03 §5](03_promotion_pipeline.md). If the regex for the
suffix convention breaks, a PROD deployment silently serves DEV numbers and
nothing fails. Assert it.

### Test the aggregation, not the rendering

The bug class that actually reaches users in a dashboard is a wrong number, and
wrong numbers come from aggregation mistakes. The reference app has one worth
copying:

```python
def test_return_rate_is_units_weighted():
    """A 1-unit SKU must not weigh the same as a 10,000-unit SKU."""
    # mean of the rates would be 0.50; the correct answer is ~0.0001
    rows = [
        {"UNITS_SOLD": 1,     "RETURN_RATE": 1.0},
        {"UNITS_SOLD": 10000, "RETURN_RATE": 0.0},
    ]
    weighted = sum(r["UNITS_SOLD"] * r["RETURN_RATE"] for r in rows) \
             / sum(r["UNITS_SOLD"] for r in rows)
    assert weighted < 0.01            # not 0.5
```

Also assert the zero-denominator case, because a dashboard that renders `NaN` in
front of an executive is a worse outcome than one that fails loudly:

```python
def test_zero_units_does_not_divide_by_zero():
    assert compute_return_rate(units=0, returns=0) == 0
```

### What is not worth unit-testing

Widget behaviour. Mocking `st.session_state` to assert that a multiselect
retained a value tests your mock, not Streamlit. The four session-state rules in
[06 §4](06_tooling_and_runtimes.md) are structural — they are enforced by code
review and by the shape of the code, not by tests. A lint rule that rejects
`default=` on a keyed widget is more valuable than any test here:

```bash
# a keyed widget must not also pass default= / value= / index=
grep -nE 'key="flt_' -A 2 demo_app/streamlit/sales_performance/streamlit_app.py \
  | grep -E 'default=|value=|index=' \
  && { echo "FAIL: keyed widget also passes a literal default"; exit 1; } \
  || echo "OK: no keyed widget passes a literal default"
```

---

## Layer 3 — Plan

Always, before every deploy. `PLAN` renders the Jinja, compiles every statement,
checks privileges, and shows the changeset — without applying anything.

```bash
snow dcm plan --target dev --save-output
```

Read the changeset rather than just checking the exit code. Three things to look
for:

| In the plan | Means |
|---|---|
| Unexpected `DROP` | Something fell out of the definitions. **Stop.** |
| `CREATE` where you expected `ALTER` | The object is not where you think it is, or a previous deploy failed |
| Empty changeset | Already in sync. A no-op deploy is fine and often correct |

A code-only change should produce exactly one `ALTER` advancing
`default_version_name`. If it produces more, read why.

Gate production on the absence of destructive operations:

```bash
python -c "
import json, sys
plan = json.load(open('out/plan_result.json'))
drops = [c['object_id']['fqn'] for c in plan['changeset']
         if c['type'] == 'DROP'
         and c['object_id']['domain'] in ('DATABASE','SCHEMA','TABLE','STAGE')]
if drops:
    print('BLOCKED -- plan drops:', *drops, sep='\n  '); sys.exit(1)
print('no destructive operations')
"
```

Note what `PLAN` does **not** do, so you do not over-trust it:

- It does not run the app.
- It does not freeze the changeset. `DEPLOY` recomputes against live state, so an
  intervening change can make the applied changeset differ from the plan.
- `PLAN DELTA` skips unchanged definitions entirely, so it will not notice that
  someone dropped a view outside DCM. Run a full `PLAN` before deploying.

---

## Layer 4 — Deploy-time checks

After `DEPLOY`, assert the objects exist and read correctly. This catches the
case where the DDL succeeded but the data did not arrive — which is the normal
state on a first deploy, because **DCM has no `DEFINE` for table contents** and
the seed is a separate hook.

```sql
-- the app's contract is the view, so test the view
SELECT COUNT(*) AS rows_in_view FROM RETAIL_DEMO_DEV.SERVE.V_SALES_PERFORMANCE;
```

Zero rows here is the single most common "the dashboard is broken" report after
a clean deploy, and the fix is to run the seed hook:

```bash
snow sql -f demo_app/hooks/seed_data.sql \
  --variable "env_suffix=_DEV" --enable-templating JINJA
```

Then assert the shape the app actually depends on:

```sql
SELECT
    COUNT(*)                                                    AS rows,
    COUNT(DISTINCT PRODUCT_LINE)                                AS product_lines,
    COUNT_IF(RETURN_RATE < 0 OR RETURN_RATE > 1)                AS impossible_rates,
    COUNT_IF(NET_REVENUE > GROSS_REVENUE)                       AS impossible_revenue,
    COUNT_IF(UNITS_SOLD < 0)                                    AS negative_units
FROM RETAIL_DEMO_DEV.SERVE.V_SALES_PERFORMANCE;
```

Every `impossible_*` column must be zero. These are cheap invariants and they
catch the arithmetic errors that a row count will not.

---

## Layer 5 — Smoke test

**This is the layer the other five cannot replace, and the one teams skip.**

### Headless execution

The Snowflake CLI can run a deployed app without a browser:

```bash
snow streamlit execute MY_DB.MY_SCHEMA.MY_APP
```

**Verified caveat:** on a container-runtime app this returned
`001022 (0A000): SQL compilation error: Operation not supported.` So do not
build a CI gate on it without confirming it works for your runtime first. Test
it manually once before you rely on it.

### Get the URL and check it

```bash
snow streamlit get-url MY_DB.MY_SCHEMA.MY_APP
```

For a container-runtime app the check that matters is whether the service came
up, which the logs will tell you:

```bash
snow streamlit logs MY_DB.MY_SCHEMA.MY_APP
```

An `ImportError` or `ModuleNotFoundError` here is the dependency mismatch from
layer 1 reaching runtime. This is the single highest-value command in this
document when an app is "broken" and nobody knows why.

### The in-app self-check

The reference app displays its own resolved Streamlit version and the commit it
was built from:

```python
st.caption(f"Streamlit runtime: `{st.__version__}`")
render_provenance_caption(resolve_provenance(conn, env))
```

This is not decoration. `DESCRIBE STREAMLIT` returns an **empty**
`user_packages` for container-runtime apps regardless of what you pinned, so
reporting `st.__version__` from inside the running app is the only way to
confirm the pin took effect. If that caption does not read the version you
pinned, your `requirements.txt` is not being applied.

### Manual checklist, for a Tier 3 promotion

Automation will not tell you the numbers are right. Before certifying:

- [ ] App loads with no traceback
- [ ] Every filter changes the displayed data
- [ ] Clearing all filters returns to the full dataset
- [ ] Deselecting one filter value does not bring it back on the next rerun
      (this is the exact bug the four session-state rules exist to prevent)
- [ ] One number reconciles against a known-good source
- [ ] The environment badge reads the environment you think you are in
- [ ] Opened as the **viewer** role, not the owner role — see below

### Test as the viewer, not as yourself

Owner's rights means the app runs with the *owner's* privileges, so it works for
you whether or not the viewer grants are right. Opening it as yourself proves
almost nothing about whether your users can use it.

```sql
USE ROLE APP_SALES_VIEWER;
-- then open the app URL
```

This is also how you catch the grant loss described in
[07 §1](07_migration_runbook.md): `CREATE OR REPLACE STREAMLIT` silently drops
privilege grants, so an app that works perfectly for its owner can be
inaccessible to every viewer.

---

## Layer 6 — Provenance assertions

Finally, assert that what you deployed is traceable — the property the whole
governance model rests on.

```sql
CALL GOVERNANCE.APPS.SP_AUDIT_STREAMLIT_APPS();

SELECT FULL_NAME, SOURCE_MODEL, PROVENANCE, DCM_SOURCE_REF,
       SUBSTR(COMMIT_SHA, 1, 12) AS commit_sha,
       IS_UNPINNED_SOURCE, TIER, FINDINGS
FROM GOVERNANCE.APPS.V_STREAMLIT_INVENTORY_LATEST
WHERE FULL_NAME = 'RETAIL_DEMO_DEV.SERVE.SALES_PERFORMANCE';
```

| Assertion | Why it matters |
|---|---|
| `PROVENANCE <> 'NONE'` | The app came from a repository |
| `COMMIT_SHA IS NOT NULL` | You can name the commit that is running |
| `IS_UNPINNED_SOURCE = FALSE` | You deployed from a tag or commit, not a moving branch |
| `SOURCE_MODEL = 'FROM'` | Not legacy, so Git applies to it at all |

As a CI gate:

```bash
snow sql -q "
SELECT COUNT(*) AS violations
FROM GOVERNANCE.APPS.V_STREAMLIT_INVENTORY_LATEST
WHERE TIER = 'CERTIFIED'
  AND (PROVENANCE = 'NONE' OR COMMIT_SHA IS NULL OR IS_UNPINNED_SOURCE)
" --format json | python -c "
import json, sys
n = int(json.load(sys.stdin)[0]['VIOLATIONS'])
sys.exit(1) if n else print('all certified apps are traceable')
"
```

---

## Putting it in CI

```yaml
on:
  pull_request:
    branches: [main]

jobs:
  validate:
    runs-on: ubuntu-latest
    env:
      PYTHONDONTWRITEBYTECODE: '1'      # a ** glob would deploy __pycache__
    steps:
      - uses: actions/checkout@v7

      - name: Layer 1 -- static
        run: |
          python -c "
          import ast, pathlib, sys
          bad = 0
          for p in pathlib.Path('demo_app/streamlit').rglob('*.py'):
              try: ast.parse(p.read_text())
              except SyntaxError as e: print(f'FAIL {p}: {e}'); bad = 1
          sys.exit(bad)"
          test ! -f demo_app/streamlit/sales_performance/environment.yml
          grep -qE '^streamlit==[0-9]' demo_app/streamlit/sales_performance/requirements.txt

      - name: Layer 2 -- unit
        run: pytest tests/ -q

      - name: Layer 3 -- plan
        run: snow dcm plan --target dev --save-output

      - name: Layer 3b -- block destructive plans
        run: python ci/check_plan.py out/plan_result.json
```

Layers 4–6 belong in the deploy workflow rather than the PR workflow, since they
need the objects to exist. See [03 §8](03_promotion_pipeline.md) and
`.github/workflows/deploy.yml` in this repo.

---

## What good looks like

A team has this working when a PR that breaks the app fails before merge, and
the failure message names the layer. If every PR passes and apps still break
after deploy, the missing layer is almost always 5 — nobody is opening the app.

---

Previous: [07 — Migration Runbook](07_migration_runbook.md) ·
Back to [index](README.md)
