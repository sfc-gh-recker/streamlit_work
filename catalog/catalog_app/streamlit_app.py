"""
App Catalog — the curated portal for certified Streamlit apps.

WHAT THIS IS FOR
Users rejected both a browser-based catalog and a conversational shell. They do
not want to chat with their data or hunt through Snowsight; they want a short
list of apps that are known to work, filtered to their role. That is all this
is: a front door.

WHY IT READS V_APP_CATALOG AND NOT APP_REGISTRY
The registry records declared intent, which can go stale -- an app can be
deleted, lose its provenance, or be edited in Snowsight after certification.
V_APP_CATALOG joins the registry to the LATEST AUDIT and shows an app only when
both agree it is certified and provable. A stale registry row therefore cannot
surface a broken dashboard to a business user.

The Operations tab is deliberately in the same app rather than a separate admin
tool. The people who maintain the estate should see the same surface the
business sees, and the backlog should be visible rather than in someone's
spreadsheet.
"""

from __future__ import annotations

import pandas as pd
import streamlit as st

st.set_page_config(
    page_title="App Catalog",
    page_icon=":material/apps:",
    layout="wide",
)

conn = st.connection("snowflake")

GOV = "GOVERNANCE.APPS"


# ---------------------------------------------------------------------------
# Data access. Cached briefly -- the catalog changes on certification, which is
# infrequent, but stale-for-an-hour would be confusing right after a release.
# ---------------------------------------------------------------------------
@st.cache_data(ttl=300, show_spinner="Loading catalog...")
def load_catalog() -> pd.DataFrame:
    return conn.query(f"SELECT * FROM {GOV}.V_APP_CATALOG ORDER BY DOMAIN, TITLE", ttl=300)


@st.cache_data(ttl=300)
def load_summary() -> pd.DataFrame:
    return conn.query(f"SELECT * FROM {GOV}.V_STREAMLIT_SPRAWL_SUMMARY", ttl=300)


@st.cache_data(ttl=300)
def load_view(view_name: str, limit: int = 200) -> pd.DataFrame:
    # view_name is chosen from a fixed set below, never user-supplied text
    return conn.query(f"SELECT * FROM {GOV}.{view_name} LIMIT {int(limit)}", ttl=300)


catalog = load_catalog()

tab_browse, tab_ops = st.tabs(["Browse apps", "Operations"])


# ===========================================================================
# BROWSE -- what business users see
# ===========================================================================
with tab_browse:
    st.title("App Catalog")
    st.caption(
        "Certified applications. Every app listed here has verified provenance, "
        "a named owner, and a support group."
    )

    if catalog.empty:
        # An empty catalog is a legitimate state, not an error, and saying so
        # plainly is more useful than an empty grid.
        st.info(
            "**No apps are certified yet.**\n\n"
            "An app appears here once it has verified provenance, a registry "
            "entry with a business owner and support group, a non-admin "
            "functional owner role, and the `FROM` source model.\n\n"
            "Certify one with:\n"
            "```sql\n"
            "CALL GOVERNANCE.APPS.SP_CERTIFY_APP('<db.schema.app>', '<your name>');\n"
            "```\n"
            "The Operations tab shows what is currently blocking certification.",
            icon=":material/info:",
        )
    else:
        c1, c2 = st.columns(2)
        with c1:
            domains = sorted(catalog["DOMAIN"].dropna().unique().tolist())
            sel_domains = st.multiselect(
                "Domain", domains, key="cat_domains", placeholder="All domains"
            )
        with c2:
            personas = sorted(catalog["PERSONA"].dropna().unique().tolist())
            sel_personas = st.multiselect(
                "Persona", personas, key="cat_personas", placeholder="All personas"
            )

        shown = catalog
        if sel_domains:
            shown = shown[shown["DOMAIN"].isin(sel_domains)]
        if sel_personas:
            shown = shown[shown["PERSONA"].isin(sel_personas)]

        if shown.empty:
            st.warning("No certified apps match those filters.")
        else:
            st.caption(f"{len(shown)} of {len(catalog)} apps")

            # Card grid. Three across reads well on a laptop without forcing
            # horizontal scroll on a smaller window.
            for chunk_start in range(0, len(shown), 3):
                cols = st.columns(3)
                for col, (_, app) in zip(
                    cols, shown.iloc[chunk_start : chunk_start + 3].iterrows()
                ):
                    with col, st.container(border=True):
                        st.subheader(app["TITLE"] or app["FULL_NAME"])
                        st.caption(
                            f"{app['DOMAIN'] or '--'} · {app['PERSONA'] or '--'}"
                        )
                        st.write(app["DESCRIPTION"] or "_No description provided._")

                        if app["APP_URL"]:
                            st.link_button(
                                "Open app",
                                app["APP_URL"],
                                use_container_width=True,
                            )

                        with st.expander("Details"):
                            st.markdown(
                                f"""
                                **Business owner** {app['BUSINESS_OWNER'] or '--'}
                                **Technical owner** {app['TECHNICAL_OWNER'] or '--'}
                                **Support** {app['SUPPORT_GROUP'] or '--'}
                                **Classification** {app['DATA_CLASSIFICATION'] or '--'}
                                **Runtime** {app['RUNTIME'] or '--'}
                                **Provenance** {app['PROVENANCE']} · `{app['provenance_detail'] or '--'}`
                                **Last reviewed** {app['LAST_REVIEWED'] or 'never'}
                                """
                            )
                            st.code(app["FULL_NAME"], language=None)


# ===========================================================================
# OPERATIONS -- what the platform team needs
# ===========================================================================
with tab_ops:
    st.title("Estate operations")
    st.caption(
        "Derived from the latest audit run. Refresh with "
        "`CALL GOVERNANCE.APPS.SP_AUDIT_STREAMLIT_APPS()`."
    )

    summary = load_summary()

    if summary.empty:
        st.warning(
            "No audit has been run. Deploy `audit/streamlit_inventory.sql`, then "
            "call `GOVERNANCE.APPS.SP_AUDIT_STREAMLIT_APPS()`."
        )
    else:
        s = summary.iloc[0]

        m1, m2, m3, m4 = st.columns(4)
        m1.metric("Apps in account", f"{int(s['TOTAL_APPS']):,}")
        m2.metric(
            "No provenance",
            f"{int(s['NO_PROVENANCE']):,}",
            f"{s['PCT_UNGOVERNED']}% of estate",
            delta_color="inverse",
        )
        m3.metric(
            "Legacy source model",
            f"{int(s['LEGACY_SOURCE_MODEL']):,}",
            "cannot use Git",
            delta_color="inverse",
        )
        m4.metric("Certified", f"{int(s['TIER_CERTIFIED']):,}")

        st.divider()

        # The legacy count is the sequencing dependency, so call it out rather
        # than leaving it as one number among many.
        legacy = int(s["LEGACY_SOURCE_MODEL"])
        total = int(s["TOTAL_APPS"])
        if legacy:
            st.warning(
                f"**{legacy} of {total} apps use the legacy `ROOT_LOCATION` "
                "source model.** Those apps cannot use Git integration or the "
                "container runtime at all, and must be migrated to `FROM` "
                "before any Git-based workflow applies to them. Since Streamlit "
                "ownership also cannot be transferred, combine the migration "
                "with re-owning so each app is only recreated once.",
                icon=":material/warning:",
            )

        st.subheader("Tier distribution")
        tiers = pd.DataFrame(
            {
                "Tier": ["Certified", "Team", "Explore", "Remediate"],
                "Apps": [
                    int(s["TIER_CERTIFIED"]),
                    int(s["TIER_TEAM"]),
                    int(s["TIER_EXPLORE"]),
                    int(s["TIER_REMEDIATE"]),
                ],
            }
        )
        st.bar_chart(tiers, x="Tier", y="Apps", horizontal=True)

        st.divider()

        ops_view = st.radio(
            "View",
            [
                "Remediation queue",
                "Unregistered apps",
                "Certification conflicts",
                "Review due",
                "Orphaned registry entries",
                "By database",
            ],
            key="ops_view",
            horizontal=True,
        )

        VIEW_MAP = {
            "Remediation queue": (
                "V_STREAMLIT_REMEDIATION_QUEUE",
                "Scored worst-first. Higher score means more findings on one app.",
            ),
            "Unregistered apps": (
                "V_UNREGISTERED_APPS",
                "Running in the account with no registry entry. Tier 1 Explore apps "
                "are excluded on purpose -- personal experiments are not meant to "
                "be registered.",
            ),
            "Certification conflicts": (
                "V_CERTIFICATION_CONFLICTS",
                "Declared certified in the registry, but the audit finds no "
                "provenance. These need resolving before anyone relies on them.",
            ),
            "Review due": (
                "V_REVIEW_DUE",
                "Past the review interval, never reviewed, or past a retirement date.",
            ),
            "Orphaned registry entries": (
                "V_ORPHANED_REGISTRY_ENTRIES",
                "Registered but no longer present in the account. Someone may still "
                "believe they own a dashboard that has been deleted.",
            ),
            "By database": (
                "V_STREAMLIT_BY_DATABASE",
                "Where the sprawl concentrates.",
            ),
        }

        view_name, blurb = VIEW_MAP[ops_view]
        st.caption(blurb)

        df = load_view(view_name)
        if df.empty:
            st.success("Nothing outstanding here.", icon=":material/check_circle:")
        else:
            st.dataframe(df, use_container_width=True, hide_index=True)

    st.divider()
    st.caption(f"Streamlit runtime: `{st.__version__}`")
