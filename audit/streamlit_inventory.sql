-- ============================================================================
-- Streamlit Sprawl Audit
-- ============================================================================
-- Builds a governed inventory of every Streamlit app in the account and
-- classifies each one on provenance, source model, ownership and staleness.
--
-- WHY THIS IS A PROCEDURE AND NOT A VIEW
-- There is no SNOWFLAKE.ACCOUNT_USAGE.STREAMLITS view. Verified: the
-- ACCOUNT_USAGE schema exposes STAGES and TAG_REFERENCES but nothing for
-- Streamlit. The only sources of truth are SHOW STREAMLITS IN ACCOUNT (the
-- object list) and DESCRIBE STREAMLIT (the per-app detail, including Git
-- provenance). Neither is a queryable view, so the inventory has to be
-- materialized by looping DESCRIBE over every app.
--
-- THE GOVERNANCE SIGNAL -- AND THE TRAP IN IT
-- DESCRIBE STREAMLIT records default_version_git_commit_hash and
-- default_version_source_location_uri, which looks like a clean binary test for
-- whether an app came from a reviewed commit.
--
-- It is not quite that simple, and getting this wrong misclassifies your BEST
-- apps. Measured on this account, the three deployment paths behave differently:
--
--   1. CREATE STREAMLIT FROM @git_repo/branches/main/app/
--        source_location_uri  @DB.SCHEMA.REPO/branches/main/app/
--        git_commit_hash      POPULATED        <- provenance on the object
--
--   2. DCM DEFINE STREAMLIT FROM 'asset://name'  (deployed from local files)
--        source_location_uri  asset://name
--        git_commit_hash      EMPTY            <- but this app IS governed:
--                                                CI/CD, reviewed, reproducible
--
--   3. DCM deployed FROM a Snowflake Git repository stage
--        git_commit_hash on the STREAMLIT is empty, but
--        SHOW DEPLOYMENTS IN DCM PROJECT exposes its own git_commit_hash column
--
-- So an audit keyed only on the Streamlit object's commit hash reports a
-- fully CI/CD-managed DCM app as ungoverned -- a false positive on the most
-- governed app in the estate. The gate has to accept EITHER form of evidence:
--
--   PROVENANCE = git_commit_hash on the object          (path 1)
--             OR managed by a DCM project               (paths 2 and 3)
--
-- The audit therefore cross-references SHOW ENTITIES IN DCM PROJECT. An app
-- that has neither is genuinely ungoverned: someone clicked in Snowsight.
--
-- Run as a role that can see all databases (ACCOUNTADMIN or an audit role
-- with IMPORTED PRIVILEGES / object discovery across the account).
-- ============================================================================

CREATE DATABASE IF NOT EXISTS GOVERNANCE
  COMMENT = 'Platform governance objects: app inventory, registry, certification';

CREATE SCHEMA IF NOT EXISTS GOVERNANCE.APPS
  COMMENT = 'Streamlit app inventory and catalog registry';

-- ----------------------------------------------------------------------------
-- Inventory table
-- ----------------------------------------------------------------------------
-- One row per app per audit run. Keeping history lets you show the trend as
-- apps get remediated, which is what makes the governance story land with
-- leadership -- "ungoverned app count is down 60% this quarter".
CREATE TABLE IF NOT EXISTS GOVERNANCE.APPS.STREAMLIT_INVENTORY (
    AUDIT_RUN_TS            TIMESTAMP_LTZ,
    FULL_NAME               VARCHAR,
    DATABASE_NAME           VARCHAR,
    SCHEMA_NAME             VARCHAR,
    APP_NAME                VARCHAR,
    TITLE                   VARCHAR,
    COMMENT_TEXT            VARCHAR,
    OWNER_ROLE              VARCHAR,
    OWNER_ROLE_TYPE         VARCHAR,
    QUERY_WAREHOUSE         VARCHAR,
    URL_ID                  VARCHAR,
    CREATED_ON              TIMESTAMP_LTZ,

    -- provenance
    GIT_COMMIT_HASH         VARCHAR,
    SOURCE_LOCATION_URI     VARCHAR,
    GIT_BRANCH              VARCHAR,
    DCM_PROJECT             VARCHAR,   -- DCM project managing this app, if any
    PROVENANCE              VARCHAR,   -- GIT_DIRECT | DCM_MANAGED | NONE

    -- source model / runtime
    SOURCE_MODEL            VARCHAR,   -- FROM | ROOT_LOCATION (legacy) | UNKNOWN
    ROOT_LOCATION           VARCHAR,
    RUNTIME                 VARCHAR,   -- WAREHOUSE | CONTAINER
    COMPUTE_POOL            VARCHAR,
    RUNTIME_NAME            VARCHAR,
    MAIN_FILE               VARCHAR,
    USER_PACKAGES           VARCHAR,

    -- classification flags
    IS_UNGOVERNED           BOOLEAN,   -- no Git provenance
    IS_LEGACY_SOURCE        BOOLEAN,   -- ROOT_LOCATION: blocks Git + container runtime
    IS_ADMIN_OWNED          BOOLEAN,   -- owned by ACCOUNTADMIN / SYSADMIN / SECURITYADMIN
    IS_UNNAMED              BOOLEAN,   -- machine-generated Snowsight name
    IS_UNDOCUMENTED         BOOLEAN,   -- no human comment
    IS_DUPLICATE            BOOLEAN,   -- "Copy of" / "Backup of" / "Duplicated from"
    IS_SCRATCH              BOOLEAN,   -- test/debug/minimal naming
    IS_UNPINNED             BOOLEAN,   -- no exact streamlit== pin
    AGE_DAYS                NUMBER,

    TIER                    VARCHAR,   -- CERTIFIED | TEAM | EXPLORE | REMEDIATE
    FINDINGS                VARCHAR,   -- human-readable summary
    DESCRIBE_ERROR          VARCHAR    -- populated when DESCRIBE fails
)
COMMENT = 'Materialized Streamlit app inventory. Refreshed by SP_AUDIT_STREAMLIT_APPS.';

-- ----------------------------------------------------------------------------
-- Audit procedure
-- ----------------------------------------------------------------------------
-- Implementation notes, each of which is load-bearing:
--
-- 1. DESCRIBE STREAMLIT returns a DIFFERENT COLUMN SET for legacy vs modern
--    apps. Legacy (ROOT_LOCATION) returns fewer columns and includes
--    root_location; modern (FROM) includes live_version_location_uri and the
--    git_commit_hash columns. Selecting a named column that does not exist is
--    a compile error, so we wrap the result in OBJECT_CONSTRUCT(*) and read
--    keys out of the VARIANT. A missing key yields NULL instead of failing.
--
-- 2. FOR-loop cursor fields cannot be referenced inside a SQL statement. Every
--    value is hoisted into a local variable and bound with :var.
--
-- 3. SQLERRM cannot appear inside a SQL statement either. It is assigned to a
--    local first, then bound.
--
-- 4. Each DESCRIBE is wrapped in its own exception handler so one
--    inaccessible app cannot abort the whole audit. Apps that cannot be
--    described are still recorded, with DESCRIBE_ERROR set -- an app you
--    cannot inspect is itself a governance finding, not a row to silently drop.
CREATE OR REPLACE PROCEDURE GOVERNANCE.APPS.SP_AUDIT_STREAMLIT_APPS()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    run_ts          TIMESTAMP_LTZ;
    apps_seen       NUMBER DEFAULT 0;
    apps_failed     NUMBER DEFAULT 0;

    -- hoisted per-app locals (cursor fields cannot be used in SQL directly)
    v_db            VARCHAR;
    v_schema        VARCHAR;
    v_name          VARCHAR;
    v_fqn           VARCHAR;
    v_title         VARCHAR;
    v_comment       VARCHAR;
    v_owner         VARCHAR;
    v_owner_type    VARCHAR;
    v_wh            VARCHAR;
    v_url_id        VARCHAR;
    v_created       TIMESTAMP_LTZ;
    v_desc          VARIANT;
    v_err           VARCHAR;
    v_proj          VARCHAR;
BEGIN
    run_ts := CURRENT_TIMESTAMP();

    -- Snapshot the object list. RESULT_SCAN requires compute, so this also
    -- confirms the session has a usable warehouse.
    SHOW STREAMLITS IN ACCOUNT;

    CREATE OR REPLACE TEMPORARY TABLE GOVERNANCE.APPS._AUDIT_APP_LIST AS
    SELECT
        "database_name"    AS database_name,
        "schema_name"      AS schema_name,
        "name"             AS app_name,
        "title"            AS title,
        "comment"          AS comment_text,
        "owner"            AS owner_role,
        "owner_role_type"  AS owner_role_type,
        "query_warehouse"  AS query_warehouse,
        "url_id"           AS url_id,
        "created_on"       AS created_on
    FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

    -- ------------------------------------------------------------------
    -- Second provenance source: apps managed by a DCM project
    -- ------------------------------------------------------------------
    -- A DCM-deployed app carries NO git_commit_hash on the Streamlit object
    -- (its source_location_uri is asset://<name>), yet it is the most governed
    -- kind of app in the estate. Without this cross-reference the audit would
    -- report every CI/CD-managed app as ungoverned.
    --
    -- SHOW ENTITIES IN DCM PROJECT is per-project, so walk the projects and
    -- union their managed Streamlit objects.
    CREATE OR REPLACE TEMPORARY TABLE GOVERNANCE.APPS._AUDIT_DCM_APPS (
        FULL_NAME    VARCHAR,
        DCM_PROJECT  VARCHAR
    );

    SHOW DCM PROJECTS IN ACCOUNT;

    CREATE OR REPLACE TEMPORARY TABLE GOVERNANCE.APPS._AUDIT_DCM_PROJECTS AS
    SELECT "database_name" || '.' || "schema_name" || '.' || "name" AS project_fqn
    FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

    LET proj_cur CURSOR FOR
        SELECT project_fqn FROM GOVERNANCE.APPS._AUDIT_DCM_PROJECTS;

    FOR p IN proj_cur DO
        v_proj := p.project_fqn;
        BEGIN
            EXECUTE IMMEDIATE 'SHOW ENTITIES IN DCM PROJECT ' || v_proj;

            INSERT INTO GOVERNANCE.APPS._AUDIT_DCM_APPS (FULL_NAME, DCM_PROJECT)
            SELECT "name", :v_proj
            FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
            WHERE UPPER("object_type") = 'STREAMLIT';
        EXCEPTION
            WHEN OTHER THEN
                -- a project we cannot read is not fatal to the audit
                NULL;
        END;
    END FOR;

    LET app_cur CURSOR FOR
        SELECT database_name, schema_name, app_name, title, comment_text,
               owner_role, owner_role_type, query_warehouse, url_id, created_on
        FROM GOVERNANCE.APPS._AUDIT_APP_LIST;

    FOR app IN app_cur DO
        -- hoist every cursor field into a local before any SQL uses it
        v_db         := app.database_name;
        v_schema     := app.schema_name;
        v_name       := app.app_name;
        v_title      := app.title;
        v_comment    := app.comment_text;
        v_owner      := app.owner_role;
        v_owner_type := app.owner_role_type;
        v_wh         := app.query_warehouse;
        v_url_id     := app.url_id;
        v_created    := app.created_on;

        v_fqn  := '"' || v_db || '"."' || v_schema || '"."' || v_name || '"';
        v_desc := NULL;
        v_err  := NULL;

        BEGIN
            EXECUTE IMMEDIATE 'DESCRIBE STREAMLIT ' || v_fqn;

            -- OBJECT_CONSTRUCT(*) absorbs the legacy/modern column difference.
            SELECT OBJECT_CONSTRUCT(*)
              INTO v_desc
              FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
        EXCEPTION
            WHEN OTHER THEN
                -- SQLERRM cannot be used inside a SQL statement; hoist it.
                v_err := SQLSTATE || ' / ' || SQLERRM;
                apps_failed := apps_failed + 1;
        END;

        INSERT INTO GOVERNANCE.APPS.STREAMLIT_INVENTORY (
            AUDIT_RUN_TS, FULL_NAME, DATABASE_NAME, SCHEMA_NAME, APP_NAME,
            TITLE, COMMENT_TEXT, OWNER_ROLE, OWNER_ROLE_TYPE, QUERY_WAREHOUSE,
            URL_ID, CREATED_ON,
            GIT_COMMIT_HASH, SOURCE_LOCATION_URI, GIT_BRANCH,
            DCM_PROJECT, PROVENANCE,
            SOURCE_MODEL, ROOT_LOCATION, RUNTIME, COMPUTE_POOL, RUNTIME_NAME,
            MAIN_FILE, USER_PACKAGES,
            IS_UNGOVERNED, IS_LEGACY_SOURCE, IS_ADMIN_OWNED, IS_UNNAMED,
            IS_UNDOCUMENTED, IS_DUPLICATE, IS_SCRATCH, IS_UNPINNED, AGE_DAYS,
            TIER, FINDINGS, DESCRIBE_ERROR
        )
        SELECT
            :run_ts,
            :v_db || '.' || :v_schema || '.' || :v_name,
            :v_db, :v_schema, :v_name,
            NULLIF(:v_title, ''),
            -- Snowsight writes a JSON audit blob into comment; that is not a
            -- human description, so normalize it away.
            CASE WHEN :v_comment ILIKE '{%lastUpdatedUser%' THEN NULL
                 ELSE NULLIF(:v_comment, '') END,
            :v_owner, :v_owner_type, NULLIF(:v_wh, ''), :v_url_id, :v_created,

            d.git_hash,
            d.src_uri,
            -- pull the branch out of @repo/branches/<branch>/path
            REGEXP_SUBSTR(d.src_uri, '/branches/([^/]+)/', 1, 1, 'e', 1),

            dcm.DCM_PROJECT,
            -- Accept EITHER form of provenance. See the header comment: a
            -- DCM-managed app has no commit hash on the object but is fully
            -- governed, so keying only on git_hash misreports it.
            CASE
                WHEN d.git_hash IS NOT NULL      THEN 'GIT_DIRECT'
                WHEN dcm.DCM_PROJECT IS NOT NULL THEN 'DCM_MANAGED'
                ELSE 'NONE'
            END,

            d.source_model,
            d.root_loc,
            d.runtime,
            NULLIF(d.compute_pool, ''),
            NULLIF(d.runtime_name, ''),
            d.main_file,
            d.user_packages,

            -- ungoverned means NEITHER provenance path applies
            (d.git_hash IS NULL AND dcm.DCM_PROJECT IS NULL),
            d.source_model = 'ROOT_LOCATION',
            :v_owner IN ('ACCOUNTADMIN', 'SYSADMIN', 'SECURITYADMIN'),
            -- Snowsight auto-names apps as 16 chars of [A-Z0-9_]
            REGEXP_LIKE(:v_name, '^[A-Z0-9_]{16}$'),
            CASE WHEN :v_comment ILIKE '{%lastUpdatedUser%' OR NULLIF(:v_comment,'') IS NULL
                 THEN TRUE ELSE FALSE END,
            (COALESCE(:v_title, '') ILIKE 'Copy of%'
             OR COALESCE(:v_title, '') ILIKE 'Backup of%'
             OR COALESCE(:v_comment, '') ILIKE '%Duplicated from%'),
            -- Snowflake regex does not support the (?i) inline flag; pass 'i'
            -- as the parameters argument to REGEXP_LIKE instead.
            (REGEXP_LIKE(COALESCE(:v_name, ''),
                 '.*(TEST|DEBUG|MINIMAL|SCRATCH|TEMP|BARE|ULTRA_BASIC|REPRO).*', 'i')
             OR REGEXP_LIKE(COALESCE(:v_title, ''),
                 '.*(test|debug|minimal|scratch|temp).*', 'i')),
            -- exact pin required: range pins silently do not apply on the
            -- warehouse runtime (SNOW-3601653)
            NOT COALESCE(d.user_packages, '') RLIKE 'streamlit==[0-9]',
            DATEDIFF('day', :v_created, :run_ts),

            CASE
                WHEN :v_err IS NOT NULL                 THEN 'REMEDIATE'
                WHEN d.source_model = 'ROOT_LOCATION'   THEN 'REMEDIATE'
                -- either provenance path qualifies as certified
                WHEN d.git_hash IS NOT NULL
                     OR dcm.DCM_PROJECT IS NOT NULL     THEN 'CERTIFIED'
                WHEN :v_owner NOT IN ('ACCOUNTADMIN','SYSADMIN','SECURITYADMIN')
                     AND NOT REGEXP_LIKE(:v_name, '^[A-Z0-9_]{16}$')
                                                        THEN 'TEAM'
                ELSE 'EXPLORE'
            END,

            ARRAY_TO_STRING(ARRAY_COMPACT(ARRAY_CONSTRUCT(
                IFF(d.git_hash IS NULL AND dcm.DCM_PROJECT IS NULL,
                    'no provenance: not from Git and not DCM-managed', NULL),
                IFF(d.source_model = 'ROOT_LOCATION',
                    'legacy ROOT_LOCATION: cannot use Git or container runtime', NULL),
                IFF(:v_owner IN ('ACCOUNTADMIN','SYSADMIN','SECURITYADMIN'),
                    'admin-owned: viewers inherit admin rights', NULL),
                IFF(REGEXP_LIKE(:v_name, '^[A-Z0-9_]{16}$'),
                    'never named: created and abandoned in Snowsight', NULL),
                IFF(:v_comment ILIKE '{%lastUpdatedUser%' OR NULLIF(:v_comment,'') IS NULL,
                    'undocumented', NULL),
                IFF(COALESCE(:v_title,'') ILIKE 'Copy of%'
                    OR COALESCE(:v_title,'') ILIKE 'Backup of%'
                    OR COALESCE(:v_comment,'') ILIKE '%Duplicated from%',
                    'duplicate of another app', NULL),
                IFF(NOT COALESCE(d.user_packages,'') RLIKE 'streamlit==[0-9]',
                    'streamlit version not pinned exactly', NULL),
                IFF(DATEDIFF('day', :v_created, :run_ts) > 365,
                    'over a year old', NULL)
            )), '; '),
            :v_err
        FROM (
            SELECT
                :v_desc:default_version_git_commit_hash::VARCHAR   AS git_hash,
                :v_desc:default_version_source_location_uri::VARCHAR AS src_uri,
                :v_desc:root_location::VARCHAR                     AS root_loc,
                :v_desc:compute_pool::VARCHAR                      AS compute_pool,
                :v_desc:runtime_name::VARCHAR                      AS runtime_name,
                :v_desc:main_file::VARCHAR                         AS main_file,
                :v_desc:user_packages::VARCHAR                     AS user_packages,
                CASE
                    WHEN :v_desc IS NULL                                THEN 'UNKNOWN'
                    WHEN :v_desc:root_location IS NOT NULL              THEN 'ROOT_LOCATION'
                    WHEN :v_desc:live_version_location_uri IS NOT NULL  THEN 'FROM'
                    ELSE 'UNKNOWN'
                END                                                AS source_model,
                CASE
                    WHEN NULLIF(:v_desc:compute_pool::VARCHAR, '') IS NOT NULL
                        THEN 'CONTAINER'
                    ELSE 'WAREHOUSE'
                END                                                AS runtime
        ) d
        LEFT JOIN GOVERNANCE.APPS._AUDIT_DCM_APPS dcm
               ON dcm.FULL_NAME = :v_db || '.' || :v_schema || '.' || :v_name;

        apps_seen := apps_seen + 1;
    END FOR;

    DROP TABLE IF EXISTS GOVERNANCE.APPS._AUDIT_APP_LIST;
    DROP TABLE IF EXISTS GOVERNANCE.APPS._AUDIT_DCM_APPS;
    DROP TABLE IF EXISTS GOVERNANCE.APPS._AUDIT_DCM_PROJECTS;

    RETURN 'Audited ' || apps_seen || ' Streamlit app(s); '
        || apps_failed || ' could not be described. Run timestamp: '
        || run_ts::VARCHAR;
END;
$$;

-- ----------------------------------------------------------------------------
-- Reporting views over the latest run
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW GOVERNANCE.APPS.V_STREAMLIT_INVENTORY_LATEST AS
SELECT *
FROM GOVERNANCE.APPS.STREAMLIT_INVENTORY
WHERE AUDIT_RUN_TS = (SELECT MAX(AUDIT_RUN_TS) FROM GOVERNANCE.APPS.STREAMLIT_INVENTORY);

-- Headline numbers. This is the slide.
CREATE OR REPLACE VIEW GOVERNANCE.APPS.V_STREAMLIT_SPRAWL_SUMMARY AS
SELECT
    COUNT(*)                                              AS total_apps,
    COUNT_IF(IS_UNGOVERNED)                               AS no_provenance,
    ROUND(100.0 * COUNT_IF(IS_UNGOVERNED) / COUNT(*), 1)  AS pct_ungoverned,
    COUNT_IF(PROVENANCE = 'GIT_DIRECT')                   AS prov_git_direct,
    COUNT_IF(PROVENANCE = 'DCM_MANAGED')                  AS prov_dcm_managed,
    COUNT_IF(IS_LEGACY_SOURCE)                            AS legacy_source_model,
    COUNT_IF(IS_ADMIN_OWNED)                              AS admin_owned,
    COUNT_IF(IS_UNNAMED)                                  AS never_named,
    COUNT_IF(IS_UNDOCUMENTED)                             AS undocumented,
    COUNT_IF(IS_DUPLICATE)                                AS duplicates,
    COUNT_IF(IS_SCRATCH)                                  AS scratch_apps,
    COUNT_IF(IS_UNPINNED)                                 AS version_unpinned,
    COUNT_IF(AGE_DAYS > 365)                              AS over_one_year_old,
    COUNT_IF(DESCRIBE_ERROR IS NOT NULL)                  AS not_inspectable,
    COUNT_IF(TIER = 'CERTIFIED')                          AS tier_certified,
    COUNT_IF(TIER = 'TEAM')                               AS tier_team,
    COUNT_IF(TIER = 'EXPLORE')                            AS tier_explore,
    COUNT_IF(TIER = 'REMEDIATE')                          AS tier_remediate
FROM GOVERNANCE.APPS.V_STREAMLIT_INVENTORY_LATEST;

-- Worst offenders first: what data engineering is being asked to support
-- without having built, reviewed, or agreed to any of it.
CREATE OR REPLACE VIEW GOVERNANCE.APPS.V_STREAMLIT_REMEDIATION_QUEUE AS
SELECT
    FULL_NAME,
    TIER,
    OWNER_ROLE,
    SOURCE_MODEL,
    RUNTIME,
    AGE_DAYS,
    FINDINGS,
    -- crude priority: more findings + older + admin-owned = fix sooner
    ( IFF(IS_UNGOVERNED,    3, 0)
    + IFF(IS_LEGACY_SOURCE, 3, 0)
    + IFF(IS_ADMIN_OWNED,   2, 0)
    + IFF(IS_UNNAMED,       2, 0)
    + IFF(IS_DUPLICATE,     2, 0)
    + IFF(IS_UNDOCUMENTED,  1, 0)
    + IFF(IS_UNPINNED,      1, 0)
    + IFF(AGE_DAYS > 365,   1, 0) ) AS remediation_score
FROM GOVERNANCE.APPS.V_STREAMLIT_INVENTORY_LATEST
ORDER BY remediation_score DESC, AGE_DAYS DESC;

-- Per-database view: shows which teams are generating the sprawl.
CREATE OR REPLACE VIEW GOVERNANCE.APPS.V_STREAMLIT_BY_DATABASE AS
SELECT
    DATABASE_NAME,
    COUNT(*)                    AS apps,
    COUNT_IF(IS_UNGOVERNED)     AS ungoverned,
    COUNT_IF(IS_SCRATCH)        AS scratch,
    COUNT_IF(IS_DUPLICATE)      AS duplicates,
    COUNT_IF(IS_ADMIN_OWNED)    AS admin_owned,
    MAX(AGE_DAYS)               AS oldest_app_days
FROM GOVERNANCE.APPS.V_STREAMLIT_INVENTORY_LATEST
GROUP BY DATABASE_NAME
ORDER BY apps DESC;

-- ----------------------------------------------------------------------------
-- Weekly refresh
-- ----------------------------------------------------------------------------
-- Suspended on creation by design. Resume once you have picked the warehouse
-- and confirmed the audit role can see every database you care about.
CREATE OR REPLACE TASK GOVERNANCE.APPS.TSK_AUDIT_STREAMLIT_APPS
    WAREHOUSE = SNOW_INTELLIGENCE_DEMO_WH
    SCHEDULE  = 'USING CRON 0 6 * * 1 America/Los_Angeles'
    COMMENT   = 'Weekly Streamlit sprawl audit, Mondays 06:00 PT'
AS
    CALL GOVERNANCE.APPS.SP_AUDIT_STREAMLIT_APPS();

-- ALTER TASK GOVERNANCE.APPS.TSK_AUDIT_STREAMLIT_APPS RESUME;
