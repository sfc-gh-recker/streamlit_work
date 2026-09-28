-- ============================================================================
-- Data foundation for the Merch Performance dashboard
-- ============================================================================
-- These objects are deployed by the SAME DCM project as the Streamlit app that
-- reads them. A promotion moves the schema and the dashboard together, so the
-- app can never be pointed at a table shape that does not exist yet.
-- ============================================================================

DEFINE DATABASE FANATICS_MERCH{{ env_suffix }}
    COMMENT = 'Merch performance analytics -- {{ env_suffix }} environment. Managed by DCM.';

DEFINE SCHEMA FANATICS_MERCH{{ env_suffix }}.CORE
    COMMENT = 'Base tables and transformations';

DEFINE SCHEMA FANATICS_MERCH{{ env_suffix }}.SERVE
    COMMENT = 'Serving layer: Streamlit apps and the views they read';


-- ----------------------------------------------------------------------------
-- Base table
-- ----------------------------------------------------------------------------
-- Synthetic data. Grain: one row per SKU per league per day.
DEFINE TABLE FANATICS_MERCH{{ env_suffix }}.CORE.SKU_DAILY_SALES (
    SALE_DATE       DATE            COMMENT 'Date of sale',
    SKU             VARCHAR         COMMENT 'Stock keeping unit identifier',
    PRODUCT_NAME    VARCHAR         COMMENT 'Human readable product name',
    LEAGUE          VARCHAR         COMMENT 'NFL, NBA, MLB, NHL, NCAA',
    TEAM            VARCHAR         COMMENT 'Team the product is associated with',
    CHANNEL         VARCHAR         COMMENT 'ECOM, RETAIL, WHOLESALE, STADIUM',
    UNITS_SOLD      NUMBER(38,0)    COMMENT 'Units sold on this date',
    GROSS_REVENUE   NUMBER(38,2)    COMMENT 'Gross revenue in USD',
    RETURNS_UNITS   NUMBER(38,0)    COMMENT 'Units returned against this SKU/date'
)
COMMENT = 'Daily SKU-level merch sales. Synthetic data for demonstration.';


-- ----------------------------------------------------------------------------
-- Serving view
-- ----------------------------------------------------------------------------
-- The app reads this, not the base table. A view boundary means the app does
-- not break when the underlying grain or column names change -- the contract
-- is the view.
--
-- Note the fully qualified reference carries env_suffix, so the DEV view reads
-- the DEV table. This is templated in the DEFINE, which works. What does NOT
-- work is templating a database name into the Python -- see utils/config.py.
DEFINE VIEW FANATICS_MERCH{{ env_suffix }}.SERVE.V_MERCH_PERFORMANCE (
    SALE_DATE       COMMENT 'Date of sale',
    LEAGUE          COMMENT 'League',
    TEAM            COMMENT 'Team',
    CHANNEL         COMMENT 'Sales channel',
    PRODUCT_NAME    COMMENT 'Product name',
    UNITS_SOLD      COMMENT 'Units sold',
    GROSS_REVENUE   COMMENT 'Gross revenue USD',
    NET_REVENUE     COMMENT 'Gross revenue less estimated return value',
    RETURN_RATE     COMMENT 'Returned units as a share of units sold'
)
AS
SELECT
    SALE_DATE,
    LEAGUE,
    TEAM,
    CHANNEL,
    PRODUCT_NAME,
    UNITS_SOLD,
    GROSS_REVENUE,
    -- value the returns at the realized average unit price for that row, so a
    -- zero-unit row cannot divide by zero
    GROSS_REVENUE - (
        RETURNS_UNITS * IFF(UNITS_SOLD > 0, GROSS_REVENUE / UNITS_SOLD, 0)
    )                                                   AS NET_REVENUE,
    IFF(UNITS_SOLD > 0, RETURNS_UNITS / UNITS_SOLD, 0)  AS RETURN_RATE
FROM FANATICS_MERCH{{ env_suffix }}.CORE.SKU_DAILY_SALES;
