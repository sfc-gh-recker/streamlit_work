-- ============================================================================
-- The Streamlit app object
-- ============================================================================
-- DEFINE STREAMLIT (Public Preview) is what makes the app a first-class,
-- declaratively managed object rather than something deployed by a side
-- script. Because it lives in the same DCM project as pipeline.sql and
-- access.sql, one `snow dcm deploy` promotes the data, the access model, and
-- the dashboard as a single unit.
--
-- Two behaviours worth knowing:
--   * After the first successful deployment the app is immediately live -- DCM
--     initializes the live version for you, so no manual ALTER STREAMLIT.
--   * Removing this DEFINE statement DROPS the app on the next deployment.
--     That is the intended lifecycle: retirement is a reviewed code change.
-- ============================================================================

DEFINE STREAMLIT FANATICS_MERCH{{ env_suffix }}.SERVE.MERCH_PERFORMANCE
    FROM 'asset://merch_performance/'
    MAIN_FILE = 'streamlit_app.py'
    QUERY_WAREHOUSE = {{ warehouse }}
    -- Declared EXPLICITLY rather than relying on the default. Verified: when
    -- these two are omitted, DCM still deploys the app on the CONTAINER
    -- runtime. That silently invalidated an environment.yml shipped with the
    -- app, because environment.yml is the warehouse-runtime format and is
    -- ignored here. Stating the runtime makes the dependency file format a
    -- deliberate choice instead of a consequence of a default.
    COMPUTE_POOL = SYSTEM_COMPUTE_POOL_CPU
    RUNTIME_NAME = 'SYSTEM$ST_CONTAINER_RUNTIME_PY3_11'
    TITLE = 'Merch Performance{{ env_suffix }}'
    COMMENT = 'League and channel merch performance. Deployed via DCM project MERCH_PERFORMANCE{{ env_suffix }}.'
;

-- ----------------------------------------------------------------------------
-- Runtime choice
-- ----------------------------------------------------------------------------
-- Container runtime, chosen explicitly:
--   * it is required for any package outside the Snowflake Anaconda channel
--   * it is the only runtime the FROM source model unlocks, and legacy
--     ROOT_LOCATION apps cannot use it at all -- which is why the 60 legacy
--     apps the audit found must be migrated before they can get here
--   * container-runtime apps are NOT stored procedures, so they avoid the
--     owner's-rights stored-procedure restrictions (limits on DESCRIBE / SHOW /
--     LIST and on which built-ins can be called)
--
-- The tradeoffs to be aware of:
--   * a compute pool must exist and is billed separately from the warehouse
--   * dependencies come from PyPI via requirements.txt, so reaching a private
--     index needs an external access integration
--   * the owner role needs USAGE on the compute pool, not just the warehouse
--
-- For the warehouse runtime instead: omit COMPUTE_POOL and RUNTIME_NAME, ship
-- an environment.yml rather than requirements.txt, and confirm with
-- DESCRIBE STREAMLIT that runtime_name came back empty. Do not assume it --
-- the default is container.
