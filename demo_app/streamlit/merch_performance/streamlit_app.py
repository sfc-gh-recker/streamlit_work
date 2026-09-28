"""
Merch Performance — reference Streamlit in Snowflake app.

This app is deliberately a teaching artifact as well as a working dashboard.
The filter block below follows the four rules that came out of the September
filter-state investigation on the Fanatics app, where a deselected filter came
back after switching grids.

THE FOUR RULES
--------------
1. Seed every widget default ONCE, before any widget is instantiated.
2. A keyed widget passes NO index= / value= / default=. With a key,
   session_state is the single source of truth; supplying both makes the widget
   literal and session_state compete.
3. Reset actions are on_click CALLBACKS, never "pending flag + st.rerun()".
   Callbacks run BEFORE the script re-executes, so widgets are rebuilt from the
   already-reset value and there is nothing to correct afterwards.
4. NEVER assign to a widget-bound session_state key after that widget has
   rendered on the same run. Current Streamlit raises
   StreamlitAPIException for this; older deployed runtimes instead produce a
   stale value that reappears on the next unrelated rerun, which is far harder
   to diagnose.

Rule 4 is the one that caused the original bug, and rule 3 is what makes
fixing it structural rather than probabilistic.
"""

from __future__ import annotations

import plotly.express as px
import streamlit as st

from utils.config import (
    render_env_badge,
    render_provenance_caption,
    resolve_environment,
    resolve_provenance,
)
from utils.data import load_date_bounds, load_filter_domain, load_performance

st.set_page_config(
    page_title="Merch Performance",
    page_icon=":material/sports_football:",
    layout="wide",
)

conn = st.connection("snowflake")

# Resolve which environment we are in from the app's own runtime context.
# DCM Jinja cannot reach this file, so this is how the app knows.
env = resolve_environment(conn)

st.title("Merch Performance")
render_env_badge(env)

serve_view = env["serve_view"]
domain = load_filter_domain(serve_view)
min_date, max_date = load_date_bounds(serve_view)

# ---------------------------------------------------------------------------
# RULE 1 — seed defaults once, before any widget exists
# ---------------------------------------------------------------------------
# A single dict is the authoritative default set. There is exactly one of
# these; a second, disagreeing copy elsewhere in the file is its own bug class.
FILTER_DEFAULTS = {
    "flt_leagues": [],
    "flt_channels": [],
    "flt_dates": (min_date, max_date),
    "flt_exclude_returns": False,
}

for key, default in FILTER_DEFAULTS.items():
    # list/tuple defaults are mutable -- copy so a widget mutating the value in
    # place cannot rewrite the default for the next reset
    st.session_state.setdefault(
        key, list(default) if isinstance(default, list) else default
    )


# ---------------------------------------------------------------------------
# RULE 3 — resets are callbacks
# ---------------------------------------------------------------------------
def _clear_filters() -> None:
    """
    Reset every filter to its default.

    This runs as an on_click callback, i.e. BEFORE the next script run. By the
    time the widgets below are instantiated they read the reset values
    directly. No guard loop, no pending flag, no mid-script st.rerun().
    """
    for k, v in FILTER_DEFAULTS.items():
        st.session_state[k] = list(v) if isinstance(v, list) else v


with st.sidebar:
    st.subheader("Filters")

    # -----------------------------------------------------------------------
    # RULE 2 — keyed widgets take no default= / value= / index=
    # -----------------------------------------------------------------------
    st.multiselect(
        "League",
        options=domain["leagues"],
        key="flt_leagues",
        placeholder="All leagues",
    )
    st.multiselect(
        "Channel",
        options=domain["channels"],
        key="flt_channels",
        placeholder="All channels",
    )
    st.date_input(
        "Date range",
        min_value=min_date,
        max_value=max_date,
        key="flt_dates",
    )
    st.toggle("Exclude returns from revenue", key="flt_exclude_returns")

    st.button(
        "Clear filters",
        on_click=_clear_filters,
        use_container_width=True,
    )

    st.divider()
    st.caption(f"Environment: **{env['env_label']}**")
    st.caption(f"Source: `{serve_view}`")
    # Report the RESOLVED Streamlit version. This is the only reliable way to
    # confirm the requirements.txt pin took effect on the container runtime --
    # the user_packages column of DESCRIBE STREAMLIT comes back empty for
    # container-runtime apps, so it cannot be used as the check. If this does
    # not read 1.52.2, the pin is not being applied.
    st.caption(f"Streamlit runtime: `{st.__version__}`")

    # Self-evidencing provenance. An app that can name the commit it was
    # built from is auditable without anyone taking its word for it.
    render_provenance_caption(resolve_provenance(conn, env))

# ---------------------------------------------------------------------------
# Read filter values from session_state -- never from widget return values.
# Reading the single source of truth keeps behaviour identical whether the run
# was triggered by a widget, a callback, or an unrelated rerun.
# ---------------------------------------------------------------------------
sel_leagues = st.session_state["flt_leagues"]
sel_channels = st.session_state["flt_channels"]
date_range = st.session_state["flt_dates"]
exclude_returns = st.session_state["flt_exclude_returns"]

# st.date_input returns a 1-tuple while the user is mid-selection
if not isinstance(date_range, (list, tuple)) or len(date_range) != 2:
    st.info("Select an end date to continue.")
    st.stop()

start_date, end_date = date_range

df = load_performance(serve_view, start_date, end_date)

# Empty selection means "all" -- more intuitive than forcing users to tick
# every box, and it keeps the query simpler than a dynamic IN list.
if sel_leagues:
    df = df[df["LEAGUE"].isin(sel_leagues)]
if sel_channels:
    df = df[df["CHANNEL"].isin(sel_channels)]

if df.empty:
    st.warning("No sales match the current filters.")
    st.stop()

revenue_col = "NET_REVENUE" if exclude_returns else "GROSS_REVENUE"
revenue_label = "Net revenue" if exclude_returns else "Gross revenue"

# ---------------------------------------------------------------------------
# Headline metrics
# ---------------------------------------------------------------------------
total_revenue = float(df[revenue_col].sum())
total_units = int(df["UNITS_SOLD"].sum())
# weight the return rate by units; a plain mean would treat a 1-unit row and a
# 10,000-unit row as equally significant
weighted_returns = (
    float((df["UNITS_SOLD"] * df["RETURN_RATE"]).sum() / total_units)
    if total_units
    else 0.0
)

c1, c2, c3, c4 = st.columns(4)
c1.metric(revenue_label, f"${total_revenue:,.0f}")
c2.metric("Units sold", f"{total_units:,}")
c3.metric("Return rate", f"{weighted_returns:.1%}")
c4.metric("Avg unit price", f"${total_revenue / total_units:,.2f}" if total_units else "—")

st.divider()

# ---------------------------------------------------------------------------
# Trend and breakdown
# ---------------------------------------------------------------------------
left, right = st.columns([3, 2])

with left:
    st.subheader(f"{revenue_label} over time")
    trend = df.groupby("SALE_DATE", as_index=False)[revenue_col].sum()
    st.plotly_chart(
        px.line(trend, x="SALE_DATE", y=revenue_col, markers=True),
        use_container_width=True,
    )

with right:
    st.subheader("By league")
    by_league = (
        df.groupby("LEAGUE", as_index=False)[revenue_col]
        .sum()
        .sort_values(revenue_col, ascending=False)
    )
    st.plotly_chart(
        px.bar(by_league, x="LEAGUE", y=revenue_col),
        use_container_width=True,
    )

st.subheader("Channel detail")
by_channel = (
    df.groupby(["CHANNEL", "LEAGUE"], as_index=False)
    .agg({revenue_col: "sum", "UNITS_SOLD": "sum"})
    .sort_values(revenue_col, ascending=False)
)
st.dataframe(by_channel, use_container_width=True, hide_index=True)
