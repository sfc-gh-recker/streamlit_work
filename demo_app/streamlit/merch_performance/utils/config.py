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
