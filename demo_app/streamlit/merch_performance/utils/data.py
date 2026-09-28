"""
Data access for the Merch Performance dashboard.

Two conventions worth keeping, both of which the September filter-state
investigation reinforced:

1. Queries live here, not in the UI file. The UI file stays about layout, which
   makes the session-state behaviour easy to reason about.
2. Every user-influenced value is a bind parameter, never an f-string. Even
   when a value comes from a selectbox the app itself populated, string
   interpolation into SQL is how injection gets in later when someone swaps the
   widget for a text input.
"""

from __future__ import annotations

import pandas as pd
import streamlit as st


@st.cache_data(ttl=600, show_spinner="Loading merch performance...")
def load_performance(serve_view: str, start_date, end_date) -> pd.DataFrame:
    """
    Aggregate performance over a date window.

    serve_view is resolved from CURRENT_DATABASE() at runtime, so it is
    interpolated -- but it is NOT user input. Date bounds come from a widget
    and are bound as parameters.
    """
    conn = st.connection("snowflake")
    return conn.query(
        f"""
        SELECT
            SALE_DATE,
            LEAGUE,
            TEAM,
            CHANNEL,
            SUM(UNITS_SOLD)                                  AS UNITS_SOLD,
            SUM(GROSS_REVENUE)                               AS GROSS_REVENUE,
            SUM(NET_REVENUE)                                 AS NET_REVENUE,
            -- recompute the rate on the aggregate; averaging per-row rates
            -- would weight a 1-unit SKU the same as a 10,000-unit SKU
            IFF(SUM(UNITS_SOLD) > 0,
                SUM(UNITS_SOLD * RETURN_RATE) / SUM(UNITS_SOLD),
                0)                                           AS RETURN_RATE
        FROM {serve_view}
        WHERE SALE_DATE BETWEEN :1 AND :2
        GROUP BY SALE_DATE, LEAGUE, TEAM, CHANNEL
        ORDER BY SALE_DATE
        """,
        params=[start_date, end_date],
        ttl=600,
    )


@st.cache_data(ttl=3600)
def load_filter_domain(serve_view: str) -> dict:
    """
    Distinct values for the filter widgets.

    Cached for an hour: the domain of leagues and channels changes far less
    often than the measures, so re-reading it on every interaction is wasted
    warehouse time.
    """
    conn = st.connection("snowflake")
    leagues = conn.query(
        f"SELECT DISTINCT LEAGUE FROM {serve_view} ORDER BY LEAGUE", ttl=3600
    )["LEAGUE"].dropna().tolist()
    channels = conn.query(
        f"SELECT DISTINCT CHANNEL FROM {serve_view} ORDER BY CHANNEL", ttl=3600
    )["CHANNEL"].dropna().tolist()
    return {"leagues": leagues, "channels": channels}


@st.cache_data(ttl=600)
def load_date_bounds(serve_view: str) -> tuple:
    """Min and max sale dates, so the date picker defaults to real data."""
    conn = st.connection("snowflake")
    df = conn.query(
        f"SELECT MIN(SALE_DATE) AS MIN_D, MAX(SALE_DATE) AS MAX_D FROM {serve_view}",
        ttl=600,
    )
    return df["MIN_D"].iloc[0], df["MAX_D"].iloc[0]
