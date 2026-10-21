-- ============================================================================
-- Seed synthetic demo data
--
-- WHY THIS IS NOT A DCM DEFINITION
-- DCM Projects are declarative: DEFINE statements describe the objects that
-- should exist, and the engine reconciles them. Loading rows is imperative --
-- there is no DEFINE for "this table should contain data" -- so it belongs in a
-- post-deployment script rather than in sources/definitions/.
--
-- The Snowflake docs call this out directly: run imperative operations in
-- separate post-deployment scripts after DEPLOY. Those scripts have their own
-- lifecycle and are not part of DCM changesets or recovery artifacts.
--
-- Without this file the reference app deploys successfully and then renders an
-- empty dashboard, which is a confusing first experience for anyone cloning the
-- repo. The data is fully synthetic.
--
-- HOW TO RUN
--   Snowflake CLI (Jinja templating must be enabled explicitly). Note the
--   value is NOT quoted: env_suffix is spliced into an identifier, so
--   "env_suffix='_DEV'" would render RETAIL_DEMO'_DEV' and fail to compile.
--     snow sql -f demo_app/hooks/seed_data.sql \
--       --variable "env_suffix=_DEV" --enable-templating JINJA
--
--   For the PROD target the suffix is empty, which needs an explicit empty
--   value rather than omitting the flag:
--     snow sql -f demo_app/hooks/seed_data.sql \
--       --variable "env_suffix=" --enable-templating JINJA
--
--   SQL, from a stage or Git repository clone:
--     EXECUTE IMMEDIATE FROM '@<repo>/branches/main/demo_app/hooks/seed_data.sql'
--       USING (env_suffix => '_DEV');
--
-- Idempotent: truncates before inserting, so re-running does not duplicate.
-- Loads roughly 8k rows spanning two years.
-- ============================================================================

TRUNCATE TABLE IF EXISTS RETAIL_DEMO{{ env_suffix }}.CORE.SKU_DAILY_SALES;

-- 2 years of daily rows across 5 product lines x 4 regions x 4 channels.
-- Deterministic: SEQ4() drives every value, so two runs produce identical data
-- and a figure in a screenshot still matches after a rebuild.
INSERT INTO RETAIL_DEMO{{ env_suffix }}.CORE.SKU_DAILY_SALES
    (SALE_DATE, SKU, PRODUCT_NAME, PRODUCT_LINE, REGION, CHANNEL,
     UNITS_SOLD, GROSS_REVENUE, RETURNS_UNITS)
WITH dims AS (
    SELECT
        d.seq                                       AS day_offset,
        pl.product_line,
        r.region,
        c.channel,
        pl.idx                                      AS pl_idx,
        r.idx                                       AS r_idx,
        c.idx                                       AS c_idx
    FROM (
        SELECT SEQ4() AS seq
        FROM TABLE(GENERATOR(ROWCOUNT => 730))
    ) d
    CROSS JOIN (
        SELECT * FROM VALUES
            (0, 'Apparel'), (1, 'Footwear'), (2, 'Accessories'),
            (3, 'Equipment'), (4, 'Outerwear')
        AS t(idx, product_line)
    ) pl
    CROSS JOIN (
        SELECT * FROM VALUES
            (0, 'North'), (1, 'South'), (2, 'East'), (3, 'West')
        AS t(idx, region)
    ) r
    CROSS JOIN (
        SELECT * FROM VALUES
            (0, 'ECOM'), (1, 'RETAIL'), (2, 'WHOLESALE'), (3, 'PARTNER')
        AS t(idx, channel)
    ) c
    -- one row per product_line/region/channel every 7th day keeps the volume
    -- demo-sized rather than loading 58k rows nobody will look at
    WHERE MOD(d.seq + pl.idx + r.idx + c.idx, 7) = 0
),
shaped AS (
    SELECT
        DATEADD('day', -day_offset, CURRENT_DATE())         AS sale_date,
        'SKU-' || LPAD(TO_VARCHAR(pl_idx * 100 + r_idx * 10 + c_idx), 5, '0')
                                                            AS sku,
        product_line || ' - ' || region                     AS product_name,
        product_line,
        region,
        channel,
        c_idx,
        -- a weekly seasonal shape plus a channel skew, so the charts have
        -- something to show rather than flat noise
        GREATEST(1,
            40
            + CAST(25 * SIN(day_offset / 7.0) AS INT)
            + pl_idx * 6
            - c_idx * 4
        )                                                   AS units_sold,
        18.00 + pl_idx * 7.50 + c_idx * 2.25                AS unit_price
    FROM dims
)
SELECT
    sale_date,
    sku,
    product_name,
    product_line,
    region,
    channel,
    units_sold,
    ROUND(units_sold * unit_price, 2)                       AS gross_revenue,
    -- returns run 2-12% depending on channel; ECOM returns more than wholesale
    CAST(units_sold * (0.02 + c_idx * 0.025) AS INT)        AS returns_units
FROM shaped
;

-- Confirm the load. Expect a non-zero count and a two-year date span.
SELECT
    COUNT(*)                                AS rows_loaded,
    COUNT(DISTINCT PRODUCT_LINE)            AS product_lines,
    COUNT(DISTINCT REGION)                  AS regions,
    COUNT(DISTINCT CHANNEL)                 AS channels,
    MIN(SALE_DATE)                          AS earliest,
    MAX(SALE_DATE)                          AS latest
FROM RETAIL_DEMO{{ env_suffix }}.CORE.SKU_DAILY_SALES;
