#!/usr/bin/env python3
"""End-to-end validation of the guide: every runnable claim, checked.

Layers 1-2 run locally (static + link integrity).
Layer 3+ is run separately against Snowflake.
"""
import re, ast, pathlib, sys
import xml.etree.ElementTree as ET
from html.parser import HTMLParser

BASE = pathlib.Path(__file__).resolve().parent
fails, warns, passes = [], [], []

def ok(m):   passes.append(m)
def bad(m):  fails.append(m)
def warn(m): warns.append(m)

# ============================================================
# 1. Python syntax
# ============================================================
pys = sorted((BASE / 'demo_app').rglob('*.py')) + sorted((BASE / 'catalog').rglob('*.py'))
for f in pys:
    try:
        ast.parse(f.read_text())
    except SyntaxError as e:
        bad('syntax %s: %s' % (f.relative_to(BASE), e))
ok('%d python files parse' % len(pys))

# ============================================================
# 2. App imports resolve against the files that exist
# ============================================================
app = BASE / 'demo_app/streamlit/sales_performance'
src = (app / 'streamlit_app.py').read_text()
tree = ast.parse(src)
imported = {}
for node in ast.walk(tree):
    if isinstance(node, ast.ImportFrom) and node.module and node.module.startswith('utils'):
        imported[node.module] = [a.name for a in node.names]
for mod, names in imported.items():
    target = app / (mod.replace('.', '/') + '.py')
    if not target.exists():
        bad('import %s has no file %s' % (mod, target.relative_to(BASE)))
        continue
    defined = {n.name for n in ast.walk(ast.parse(target.read_text()))
               if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef))}
    for n in names:
        if n not in defined:
            bad('%s imports %s from %s, which does not define it' % ('streamlit_app.py', n, mod))
    ok('%s -> %s (%d symbols resolve)' % (mod, target.name, len(names)))

# ============================================================
# 3. Columns the app reads must exist in the view definition
# ============================================================
pipeline = (BASE / 'demo_app/sources/definitions/pipeline.sql').read_text()
view_block = pipeline.split('DEFINE VIEW', 1)[1] if 'DEFINE VIEW' in pipeline else ''
appsql = src + (app / 'utils/data.py').read_text()
# Columns the app may legitimately reference without the view declaring them:
# anything it aliases itself inside a SELECT (e.g. MIN(SALE_DATE) AS MIN_D).
aliases = set(re.findall(r'\bAS\s+([A-Z_]{2,})\b', appsql))
unresolved = []
for col in sorted(set(re.findall(r'df\[[\'"]([A-Z_]+)[\'"]\]', appsql))
                  | set(re.findall(r'groupby\(\[?[\'"]([A-Z_]+)[\'"]', appsql))):
    if col not in view_block and col not in aliases:
        unresolved.append(col)
if unresolved:
    for col in unresolved:
        bad('app reads column %s which is neither in the view nor aliased' % col)
else:
    ok('app columns all resolve (view definition or self-declared alias)')

# seed must populate every column the table declares (minus generated)
seed = (BASE / 'demo_app/hooks/seed_data.sql').read_text()
tbl_block = pipeline.split('DEFINE TABLE', 1)[1].split(')', 1)[0]
declared = re.findall(r'^\s{4}([A-Z_]+)\s+(?:DATE|VARCHAR|NUMBER)', tbl_block, re.M)
insert_cols = re.search(r'INSERT INTO [^\(]+\(([^)]+)\)', seed, re.S)
if insert_cols:
    seeded = {c.strip() for c in insert_cols.group(1).replace('\n', ' ').split(',')}
    missing = [c for c in declared if c not in seeded]
    if missing:
        bad('seed does not populate declared columns: %s' % ', '.join(missing))
    else:
        ok('seed populates all %d declared columns' % len(declared))

# ============================================================
# 4. Session-state rules are actually followed in the reference app
# ============================================================
# Rule 2: a keyed widget must not also pass default=/value=/index=
for m in re.finditer(r'st\.(multiselect|selectbox|date_input|checkbox|radio)\((.*?)\n    \)', src, re.S):
    blk = m.group(2)
    if 'key=' in blk and re.search(r'\b(default|value|index)\s*=', blk):
        bad('rule 2 violated: keyed %s also passes a literal default' % m.group(1))
ok('rule 2: no keyed widget passes a literal default')

# Rule 3: resets are on_click callbacks, not pending-flag + rerun
if 'st.rerun()' in src and 'on_click' not in src:
    bad('rule 3 risk: st.rerun() present with no on_click callback')
else:
    ok('rule 3: reset uses an on_click callback')

# Rule 1: defaults seeded once via setdefault
if 'FILTER_DEFAULTS' in src and 'setdefault' in src:
    ok('rule 1: defaults seeded once via setdefault')
else:
    bad('rule 1: no single FILTER_DEFAULTS + setdefault seeding found')

# ============================================================
# 5. Dependency pinning and runtime agreement
# ============================================================
req = app / 'requirements.txt'
if (app / 'environment.yml').exists():
    bad('environment.yml present on a container-runtime app (silently ignored)')
else:
    ok('no environment.yml on the container-runtime app')
if re.search(r'^streamlit==[0-9]', req.read_text(), re.M):
    ok('streamlit pinned exactly')
else:
    bad('streamlit not pinned exactly (range pins silently do not apply)')

dash = (BASE / 'demo_app/sources/definitions/dashboard.sql').read_text()
if 'RUNTIME_NAME' in dash and 'COMPUTE_POOL' in dash:
    ok('DEFINE STREAMLIT declares runtime and compute pool explicitly')
else:
    bad('DEFINE STREAMLIT does not declare the runtime (it defaults to container)')

# ============================================================
# 6. DCM manifest shape
# ============================================================
man = (BASE / 'demo_app/manifest.yml').read_text()
for need in ['manifest_version: 2', 'type: DCM_PROJECT', 'default_target', 'templating']:
    if need not in man:
        bad('manifest missing %s' % need)
if "path: 'streamlit/sales_performance/**/*'" in man or '**/*' in man:
    ok('asset uses a ** glob (only form that preserves package structure)')
else:
    bad('asset path is not a ** glob -- directories will flatten')
for placeholder in ['MYORG-MYACCOUNT', 'ANALYTICS_WH']:
    if placeholder not in man:
        warn('manifest does not use the %s placeholder' % placeholder)
ok('manifest_version 2 shape present')

# ============================================================
# 7. Doc cross-links all resolve
# ============================================================
docs = sorted(BASE.rglob('*.md'))
broken = 0
for d in docs:
    if '.git' in d.parts or '.snowflake' in d.parts:
        continue
    for link in re.findall(r'\]\(([^)#]+\.md)(?:#[^)]*)?\)', d.read_text()):
        if link.startswith(('http://', 'https://')):
            continue
        target = (d.parent / link).resolve()
        if not target.exists():
            bad('broken link in %s -> %s' % (d.relative_to(BASE), link))
            broken += 1
if not broken:
    ok('all %d markdown files have resolving internal links' % len(docs))

# strategy set must be complete 00-08 + README
strat = BASE / 'streamlit_strategy_v1'
expected = ['README.md'] + ['%02d_' % i for i in range(0, 9)]
present = {p.name for p in strat.glob('*.md')}
for i in range(0, 9):
    if not any(n.startswith('%02d_' % i) for n in present):
        bad('strategy set missing document %02d' % i)
ok('strategy set has %d documents' % len(present))

# ============================================================
# 8. HTML sandbox compliance
# ============================================================
h = BASE / 'streamlit-dev-management-guide.html'
s = h.read_text()
for tag in re.findall(r'<(?:script|link|img|iframe|source|embed|object)\b[^>]*>', s, re.I):
    for u in re.findall(r'(?:src|href|data)\s*=\s*["\']([^"\']+)', tag, re.I):
        if u.startswith(('http://', 'https://', '//')):
            bad('remote subresource: ' + u)
        elif u.startswith('/') and not u.startswith('/libs/'):
            bad('bad absolute subresource: ' + u)
if re.search(r'\son(?:click|load|error|mouse\w+|key\w+|submit|change)\s*=', s, re.I):
    bad('inline event handler in HTML')
if re.search(r'\beval\s*\(|\bfetch\s*\(|XMLHttpRequest', s):
    bad('eval or network call in HTML')
for k in ['name="snowflake-source"', 'snowflake-report-metadata', 'light-dark(', 'color-scheme']:
    if k not in s:
        bad('HTML missing ' + k)
hids = set(re.findall(r'\bid="([^"]+)"', s))
mm = re.search(r'snowflake-report-metadata[^>]*>(.*?)</script>', s, re.S)
if mm:
    for a in re.findall(r'"anchor"\s*:\s*"#?([^"]+)"', mm.group(1)):
        if a not in hids:
            bad('dangling HTML metadata anchor: ' + a)
nt, nw = len(re.findall(r'<table\b', s)), len(re.findall(r'class="table-wrap"', s))
if nt > nw:
    bad('%d HTML tables but %d wrappers' % (nt, nw))
VOID = {'area','base','br','col','embed','hr','img','input','link','meta','source','track','wbr'}
class P(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True); self.st=[]; self.bad=[]
    def handle_starttag(self, t, a):
        if t not in VOID: self.st.append(t)
    def handle_endtag(self, t):
        if t in VOID: return
        if not self.st: self.bad.append('stray </%s>' % t); return
        if self.st[-1] == t: self.st.pop()
        elif t in self.st:
            while self.st and self.st[-1] != t: self.bad.append('unclosed <%s>' % self.st.pop())
            if self.st: self.st.pop()
        else: self.bad.append('unmatched </%s>' % t)
pr = P(); pr.feed(s)
for b in pr.bad + ['unclosed <%s>' % t for t in pr.st]:
    bad('HTML ' + b)
ok('HTML passes sandbox rules (%d bytes, %d tables/%d wrappers)' % (len(s), nt, nw))

# ============================================================
# 9. Diagrams parse
# ============================================================
for rel in ['brief/lifecycle_flow.drawio', 'brief/lifecycle_flow.svg']:
    try:
        ET.parse(BASE / rel); ok('%s parses' % rel)
    except Exception as e:
        bad('%s: %s' % (rel, e))

# ============================================================
# 10. Hygiene
# ============================================================
for f in BASE.rglob('*'):
    if '.git' in f.parts: continue
    if f.name == '__pycache__' or f.suffix == '.pyc':
        bad('bytecode present: %s' % f.relative_to(BASE))
ok('no bytecode artifacts')

STALE = ['CUSTOMER_NAME', 'MERCH_PERFORMANCE', 'APP_MERCH', 'TEAM_NAME', 'PERSON_NAME',
         'ACCOUNT_LOCATOR', 'ORG_NAME']
for f in BASE.rglob('*'):
    if f.is_dir() or '.git' in f.parts or '.snowflake' in f.parts: continue
    if f.name == 'e2e_validate.py': continue
    try: txt = f.read_text()
    except (UnicodeDecodeError, PermissionError): continue
    for tok in STALE:
        if tok in txt:
            bad('customer token %r in %s' % (tok, f.relative_to(BASE)))
ok('no customer-specific tokens')

# ============================================================
print('=' * 66)
for m in passes: print('  PASS  ' + m)
if warns:
    print()
    for m in warns: print('  WARN  ' + m)
print('=' * 66)
if fails:
    print('FAILED (%d)' % len(fails))
    for m in fails: print('  FAIL  ' + m)
    sys.exit(1)
print('ALL %d LOCAL CHECKS PASSED%s' % (len(passes), ', %d warnings' % len(warns) if warns else ''))
