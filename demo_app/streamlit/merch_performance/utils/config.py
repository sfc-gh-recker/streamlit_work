"""
Environment configuration for the Merch Performance dashboard.

THE IMPORTANT CONSTRAINT
------------------------
DCM Projects Jinja variables are NOT passed through to Streamlit Python files.
You can template the DEFINE STREAMLIT statement -- warehouse, title, compute
pool -- but nothing reaches the app source.

This is the single easiest way to ship a broken multi-environment Streamlit
app. The tempting approach is to hardcode or template a database name:

    # WRONG -- deploys to PROD still pointing at DEV
    DATABASE = "FANATICS_MERCH_DEV"

That app deploys successfully to every environment and silently reads DEV data
in PROD. Nothing fails; the numbers are just wrong, which is worse.

The correct approach is to ask Snowflake at runtime where the app is running.
Because the Streamlit object lives inside the environment's own database, the
app's current database IS its environment.
"""

import re

import streamlit as st


def _current_database(conn) -> str:
    """The database the Streamlit object itself lives in."""
    return conn.query(
        "SELECT CURRENT_DATABASE() AS DB", ttl=3600
    )["DB"].iloc[0]


def resolve_environment(conn) -> dict:
    """
    Derive environment identity and the fully qualified serving view from the
    app's own runtime context.

    Returns a dict with:
        database    e.g. FANATICS_MERCH_DEV
        env_label   e.g. DEV
        is_prod     True only in the production environment
        serve_view  fully qualified view the app should read
    """
    database = _current_database(conn)

    # FANATICS_MERCH_DEV -> DEV, FANATICS_MERCH -> PROD (no suffix)
    match = re.search(r"_(DEV|TEST|STAGING|QA)$", database or "", re.IGNORECASE)
    env_label = match.group(1).upper() if match else "PROD"

    return {
        "database": database,
        "env_label": env_label,
        "is_prod": env_label == "PROD",
        "serve_view": f"{database}.SERVE.V_MERCH_PERFORMANCE",
    }


def render_env_badge(env: dict) -> None:
    """
    Make the environment unmistakable in non-production.

    Cheap, and it prevents the recurring incident where someone screenshots a
    DEV dashboard into an exec deck. In PROD this renders nothing.
    """
    if env["is_prod"]:
        return

    st.warning(
        f"**{env['env_label']} environment** — reading `{env['database']}`. "
        "Figures here are not production data.",
        icon=":material/warning:",
    )


def resolve_provenance(conn, env: dict) -> dict:
    """
    Report which deployed version of itself this app is running.

    WHY THE APP ASKS, RATHER THAN BEING TOLD
    ----------------------------------------
    A build step could stamp the commit into a generated Python constant, but
    then the badge reports what the build *intended* to ship, not what is
    actually serving traffic. Asking Snowflake at runtime cannot drift.

    WHERE THE COMMIT ACTUALLY LIVES depends on how the app was deployed, and
    the two cases do not overlap:

      Deployed with CREATE STREAMLIT FROM '@git_repo/...'
        default_version_git_commit_hash is populated on the object.

      Deployed by a DCM project (this app)
        That column is EMPTY -- source_location_uri reads 'asset://...'. The
        commit is only recoverable from the project's latest deployment, via
        SHOW DEPLOYMENTS IN DCM PROJECT, and even then only from the literal
        source_file_path string: the documented git_commit_hash column of that
        command does not populate (verified 2026-09-28). Which means a project
        deployed from '@repo/branches/main/' is unauditable -- a branch is a
        moving pointer. Deploy from '@repo/commits/<sha>/' instead.

    So this reads the object first and falls back to the governance inventory,
    which already reconciles both paths into COMMIT_SHA.
    """
    fqn = f"{env['database']}.SERVE.MERCH_PERFORMANCE"
    out = {"version": None, "commit": None, "source": None}

    try:
        desc = conn.query(f"DESCRIBE STREAMLIT {fqn}", ttl=600)
        out["version"] = desc["default_version_name"].iloc[0]
        commit = (desc["default_version_git_commit_hash"].iloc[0] or "").strip()
        if commit:
            out["commit"] = commit
            out["source"] = "app object"
    except Exception:
        # Not fatal. A viewer role may lack DESCRIBE on the Streamlit, and the
        # dashboard must still render -- provenance is a footnote, not a
        # prerequisite.
        return out

    if out["commit"]:
        return out

    # DCM-deployed: ask the governance inventory, which cross-references
    # SHOW ENTITIES / SHOW DEPLOYMENTS to recover the commit.
    try:
        row = conn.query(
            """
            SELECT COMMIT_SHA
            FROM GOVERNANCE.APPS.V_STREAMLIT_INVENTORY_LATEST
            WHERE FULL_NAME = ? AND COMMIT_SHA IS NOT NULL
            """,
            params=[fqn],
            ttl=600,
        )
        if not row.empty:
            out["commit"] = row["COMMIT_SHA"].iloc[0]
            out["source"] = "DCM deployment"
    except Exception:
        pass

    return out


def render_provenance_caption(prov: dict) -> None:
    """Render the provenance footnote, stating plainly when it is absent."""
    if prov.get("version"):
        st.caption(f"Deployed version: `{prov['version']}`")

    if prov.get("commit"):
        st.caption(
            f"Built from commit `{prov['commit'][:12]}` "
            f"(via {prov['source']})"
        )
    else:
        # Say so rather than rendering nothing. An app that cannot name its
        # own commit is exactly the app this whole workflow is about.
        st.caption("Built from commit: :orange[not traceable]")
