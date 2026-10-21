#!/usr/bin/env python3
"""
verify_provenance.py - assert a deployed Streamlit app traces to a Git commit.

WHY THIS IS NOT A ONE-LINE CHECK
Provenance is recorded in three different places depending on how the app was
deployed, and the obvious check -- reading git_commit_hash off the app object --
produces a FALSE NEGATIVE on the best-governed deployment path there is.

  path 1  CREATE STREAMLIT FROM '@repo/branches/<br>/...'
          The branch is resolved to a concrete SHA at create time and pinned on
          the version. DESCRIBE STREAMLIT.default_version_git_commit_hash is
          populated. Self-evidencing.

  path 2  EXECUTE DCM PROJECT ... DEPLOY FROM '@repo/commits/<sha>/...'
          The app object carries NO commit hash -- default_version_git_commit_hash
          is null and source_location_uri is 'asset://<name>'. Verified against a
          live DCM deployment. SHOW DEPLOYMENTS.git_commit_hash is ALSO null,
          despite being documented as recording the originating commit. The only
          retained evidence is the literal source_file_path string.

  path 3  Snowsight click-ops / workspace preview
          No evidence anywhere. Correctly fails.

So a gate written as `if not commit_hash: fail` rejects every DCM deployment --
which is exactly the governance model this repository prescribes. The check has
to accept EITHER source, which is the executable form of the documented rule
"gate on provenance = NONE, never on git_commit_hash IS NULL".

A branch-path DCM deployment is deliberately treated as a FAILURE rather than a
pass: a branch is a moving pointer, so the deployment cannot be tied to the code
that shipped. That is a different defect from having no provenance at all, and
the message says so.

Usage:
    python .github/scripts/verify_provenance.py \
        --app     RETAIL_DEMO.SERVE.SALES_PERFORMANCE \
        --project GOVERNANCE.PROJECTS.SALES_PERFORMANCE_PROD

Exits 0 when provenance is established, 1 otherwise.
"""

import argparse
import json
import re
import subprocess
import sys

SHA_IN_COMMIT_PATH = re.compile(r"/commits/([0-9a-f]{40})/")


def snow_json(query, connection=None):
    """Run a query through the Snowflake CLI and return parsed rows."""
    cmd = ["snow", "sql", "-q", query, "--format", "json"]
    if connection:
        cmd += ["-c", connection]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(
            "snow sql failed (%d): %s" % (proc.returncode, proc.stderr.strip())
        )
    try:
        parsed = json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError("could not parse snow sql output: %s" % exc)
    # A single-statement query yields a list of row dicts.
    if isinstance(parsed, dict):
        return [parsed]
    # Multi-statement output nests one list per statement; take the last.
    if parsed and isinstance(parsed[0], list):
        return parsed[-1]
    return parsed


def check_app_object(app, connection):
    """Path 1: a commit hash pinned on the app version."""
    rows = snow_json("DESCRIBE STREAMLIT %s" % app, connection)
    if not rows:
        return None, "DESCRIBE STREAMLIT returned no rows for %s" % app
    row = rows[0]
    sha = row.get("default_version_git_commit_hash")
    if sha:
        return ("GIT_DIRECT", sha), None
    return None, None


def check_dcm_project(project, connection):
    """Path 2: a commit SHA recoverable from the newest deployment's source path."""
    rows = snow_json("SHOW DEPLOYMENTS IN DCM PROJECT %s" % project, connection)
    if not rows:
        return None, "no deployments found in DCM project %s" % project

    # Do not trust SHOW ordering -- sort explicitly on created_on so the newest
    # deployment is the one assessed.
    rows.sort(key=lambda r: str(r.get("created_on") or ""), reverse=True)
    newest = rows[0]
    path = str(newest.get("source_file_path") or "")

    # Prefer the column if it is ever populated; it has been null in every
    # deployment measured, but reading it first costs nothing and future-proofs
    # the check if the product starts filling it in.
    sha = newest.get("git_commit_hash")
    if sha:
        return ("DCM_HASH", sha), None

    match = SHA_IN_COMMIT_PATH.search(path)
    if match:
        return ("DCM_COMMIT_PATH", match.group(1)), None

    if "/branches/" in path:
        return None, (
            "deployment %s was made from a BRANCH path, not a commit path:\n"
            "    %s\n"
            "A branch is a moving pointer, so the shipped code cannot be "
            "identified later. Redeploy FROM '@<repo>/commits/<sha>/...'."
            % (newest.get("alias") or newest.get("name"), path)
        )

    return None, (
        "deployment %s carries no recoverable commit. source_file_path:\n    %s"
        % (newest.get("alias") or newest.get("name"), path)
    )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", required=True, help="fully qualified Streamlit name")
    ap.add_argument(
        "--project",
        required=False,
        help="fully qualified DCM project name; omit for a non-DCM deployment",
    )
    ap.add_argument("--connection", help="Snowflake CLI connection name")
    args = ap.parse_args()

    notes = []

    try:
        found, err = check_app_object(args.app, args.connection)
    except RuntimeError as exc:
        print("FAIL: could not describe %s: %s" % (args.app, exc))
        return 1
    if err:
        print("FAIL: %s" % err)
        return 1
    if found:
        kind, sha = found
        print("PASS [%s] %s traces to commit %s" % (kind, args.app, sha))
        return 0

    notes.append(
        "app object carries no commit hash (expected for a DCM deployment)"
    )

    if not args.project:
        print("FAIL: %s" % "; ".join(notes))
        print(
            "No --project supplied, so DCM provenance could not be checked. "
            "If this app is DCM-managed, pass its project name."
        )
        return 1

    try:
        found, err = check_dcm_project(args.project, args.connection)
    except RuntimeError as exc:
        print("FAIL: could not read deployments for %s: %s" % (args.project, exc))
        return 1
    if found:
        kind, sha = found
        print("PASS [%s] %s traces to commit %s" % (kind, args.app, sha))
        print("      (%s)" % "; ".join(notes))
        return 0

    print("FAIL: %s is not eligible for the CERTIFIED tier." % args.app)
    for n in notes:
        print("  - %s" % n)
    if err:
        print("  - %s" % err)
    return 1


if __name__ == "__main__":
    sys.exit(main())
