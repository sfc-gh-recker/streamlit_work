-- ============================================================================
-- App Registry and Certification
-- ============================================================================
-- The audit (audit/streamlit_inventory.sql) records what IS -- everything it
-- knows is derived from the objects themselves. This registry records what is
-- INTENDED: the facts no amount of introspection can produce.
--
--   Who owns this in the business?
--   Who gets paged when it breaks?
--   When does it get reviewed, and when is it retired?
--
-- Neither table is sufficient alone. Joined, they surface contradictions --
-- apps declared production-ready that cannot prove their origin, apps nobody
-- registered, registered apps that no longer exist.
--
-- WHY THE REGISTRY IS THE DECLARATIVE RECORD AND TAGS ARE DERIVED
-- Streamlit IS a taggable object, so certification can be machine-readable on
-- the object via ALTER STREAMLIT ... SET TAG. But DCM Projects' ATTACH TAG does
-- NOT support STREAMLIT as a target (supported: DATABASE, SCHEMA, TABLE, VIEW,
-- DYNAMIC TABLE, FUNCTION, PROCEDURE, STAGE, TASK, ROLE, DATABASE ROLE,
-- WAREHOUSE). So tags cannot be declared in the DCM project and reconciled on
-- every deployment -- they must be applied imperatively and can drift.
-- Therefore: this table is the source of truth, the tag is a projection of it.
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS GOVERNANCE.APPS;

-- ----------------------------------------------------------------------------
-- Registry
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS GOVERNANCE.APPS.APP_REGISTRY (
    FULL_NAME            VARCHAR NOT NULL,   -- db.schema.app, matches the audit
    TITLE                VARCHAR,
    DESCRIPTION          VARCHAR,

    -- discovery
    DOMAIN               VARCHAR,            -- Commerce, Finance, Supply Chain
    PERSONA              VARCHAR,            -- Exec, Analyst, Ops, Merchandiser
    TIER                 VARCHAR,            -- EXPLORE | TEAM | CERTIFIED

    -- accountability: these are PEOPLE, deliberately
    BUSINESS_OWNER       VARCHAR,
    TECHNICAL_OWNER      VARCHAR,
    SUPPORT_GROUP        VARCHAR,            -- who gets paged

    -- access
    OWNER_ROLE           VARCHAR,            -- functional role the app runs as
    VIEWER_ROLE          VARCHAR,

    -- governance
    DATA_CLASSIFICATION  VARCHAR,            -- Public | Internal | Confidential
    COST_CENTER          VARCHAR,

    -- provenance, as declared; cross-checked against the audit
    SOURCE_REPO          VARCHAR,
    SOURCE_PATH          VARCHAR,
    DCM_PROJECT          VARCHAR,

    -- certification
    CERTIFICATION        VARCHAR DEFAULT 'NONE',  -- CERTIFIED | PENDING | NONE
    CERTIFIED_BY         VARCHAR,
    CERTIFIED_ON         DATE,

    -- lifecycle: an estate without these only ever grows
    LAST_REVIEWED        DATE,
    REVIEW_INTERVAL_DAYS NUMBER DEFAULT 180,
    RETIREMENT_DATE      DATE,

    -- presentation
    APP_URL              VARCHAR,
    ICON                 VARCHAR DEFAULT 'analytics',

    CREATED_ON           TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(),
    UPDATED_ON           TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(),

    CONSTRAINT PK_APP_REGISTRY PRIMARY KEY (FULL_NAME)
)
COMMENT = 'Declared intent for each Streamlit app. Source of truth for certification.';


-- ----------------------------------------------------------------------------
-- Lifecycle tag (derived projection of the registry)
-- ----------------------------------------------------------------------------
CREATE TAG IF NOT EXISTS GOVERNANCE.APPS.APP_LIFECYCLE
    ALLOWED_VALUES 'EXPLORE', 'TEAM', 'CERTIFIED', 'RETIRED'
    COMMENT = 'Lifecycle tier. Applied by SP_CERTIFY_APP; registry is authoritative.';

CREATE TAG IF NOT EXISTS GOVERNANCE.APPS.APP_SUPPORT_GROUP
    COMMENT = 'Team paged when this app breaks. Applied by SP_CERTIFY_APP.';


-- ============================================================================
-- Reconciliation views -- where registry meets reality
-- ============================================================================

-- The politically important one: apps somebody declared production-ready that
-- the audit says cannot prove their origin. Surfaces the contradiction without
-- anyone having to make an accusation.
CREATE OR REPLACE VIEW GOVERNANCE.APPS.V_CERTIFICATION_CONFLICTS AS
SELECT
    r.FULL_NAME,
    r.TITLE,
    r.BUSINESS_OWNER,
    r.SUPPORT_GROUP,
    r.CERTIFICATION      AS declared_certification,
    i.PROVENANCE         AS actual_provenance,
    i.TIER               AS audited_tier,
    i.FINDINGS
FROM GOVERNANCE.APPS.APP_REGISTRY r
JOIN GOVERNANCE.APPS.V_STREAMLIT_INVENTORY_LATEST i
  ON i.FULL_NAME = r.FULL_NAME
WHERE r.CERTIFICATION = 'CERTIFIED'
  AND i.IS_UNGOVERNED;

-- Apps running in the estate that nobody registered. EXPLORE-tier apps are
-- excluded deliberately -- personal experiments are not meant to be registered,
-- and demanding it would just push people back to spreadsheets.
CREATE OR REPLACE VIEW GOVERNANCE.APPS.V_UNREGISTERED_APPS AS
SELECT
    i.FULL_NAME,
    i.OWNER_ROLE,
    i.TIER,
    i.PROVENANCE,
    i.AGE_DAYS,
    i.FINDINGS
FROM GOVERNANCE.APPS.V_STREAMLIT_INVENTORY_LATEST i
LEFT JOIN GOVERNANCE.APPS.APP_REGISTRY r
  ON r.FULL_NAME = i.FULL_NAME
WHERE r.FULL_NAME IS NULL
  AND i.TIER <> 'EXPLORE';

-- Registered apps that no longer exist. Someone is still on the hook for a
-- dashboard that was deleted out from under them.
CREATE OR REPLACE VIEW GOVERNANCE.APPS.V_ORPHANED_REGISTRY_ENTRIES AS
SELECT
    r.FULL_NAME,
    r.TITLE,
    r.BUSINESS_OWNER,
    r.SUPPORT_GROUP,
    r.CERTIFICATION,
    r.LAST_REVIEWED
FROM GOVERNANCE.APPS.APP_REGISTRY r
LEFT JOIN GOVERNANCE.APPS.V_STREAMLIT_INVENTORY_LATEST i
  ON i.FULL_NAME = r.FULL_NAME
WHERE i.FULL_NAME IS NULL;

-- Overdue review or past retirement date.
CREATE OR REPLACE VIEW GOVERNANCE.APPS.V_REVIEW_DUE AS
SELECT
    FULL_NAME,
    TITLE,
    BUSINESS_OWNER,
    SUPPORT_GROUP,
    LAST_REVIEWED,
    DATEADD('day', REVIEW_INTERVAL_DAYS, LAST_REVIEWED) AS review_due_on,
    RETIREMENT_DATE,
    CASE
        WHEN RETIREMENT_DATE IS NOT NULL
             AND RETIREMENT_DATE < CURRENT_DATE()              THEN 'PAST RETIREMENT'
        WHEN LAST_REVIEWED IS NULL                             THEN 'NEVER REVIEWED'
        WHEN DATEADD('day', REVIEW_INTERVAL_DAYS, LAST_REVIEWED) < CURRENT_DATE()
                                                               THEN 'REVIEW OVERDUE'
        ELSE 'CURRENT'
    END AS review_status
FROM GOVERNANCE.APPS.APP_REGISTRY
WHERE review_status <> 'CURRENT';

-- The catalog feed. Only certified apps that still exist and still have
-- provenance -- the app portal reads this, not the registry directly, so a
-- stale registry row cannot surface a broken app to business users.
CREATE OR REPLACE VIEW GOVERNANCE.APPS.V_APP_CATALOG AS
SELECT
    r.FULL_NAME,
    r.TITLE,
    r.DESCRIPTION,
    r.DOMAIN,
    r.PERSONA,
    r.BUSINESS_OWNER,
    r.TECHNICAL_OWNER,
    r.SUPPORT_GROUP,
    r.DATA_CLASSIFICATION,
    r.VIEWER_ROLE,
    r.APP_URL,
    r.ICON,
    r.LAST_REVIEWED,
    i.PROVENANCE,
    i.RUNTIME,
    COALESCE(LEFT(i.GIT_COMMIT_HASH, 12), i.DCM_PROJECT) AS provenance_detail
FROM GOVERNANCE.APPS.APP_REGISTRY r
JOIN GOVERNANCE.APPS.V_STREAMLIT_INVENTORY_LATEST i
  ON i.FULL_NAME = r.FULL_NAME
WHERE r.CERTIFICATION = 'CERTIFIED'
  AND NOT i.IS_UNGOVERNED;


-- ============================================================================
-- Certification procedure
-- ============================================================================
-- Enforces the mechanically verifiable checks, then records certification and
-- projects it onto the object as a tag.
--
-- Checks 1-5 here are derivable. The human commitments -- business owner,
-- support group, review date -- are enforced by requiring the registry row to
-- be populated first, which is why they are arguments rather than inferred.
CREATE OR REPLACE PROCEDURE GOVERNANCE.APPS.SP_CERTIFY_APP(
    P_FULL_NAME       VARCHAR,
    P_CERTIFIED_BY    VARCHAR
)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    v_provenance     VARCHAR;
    v_legacy         BOOLEAN;
    v_admin_owned    BOOLEAN;
    v_exists         NUMBER;
    v_reg            NUMBER;
    v_biz_owner      VARCHAR;
    v_support        VARCHAR;
    v_failures       VARCHAR DEFAULT '';
    v_err            VARCHAR;
BEGIN
    -- does the app actually exist in the latest audit?
    SELECT COUNT(*) INTO v_exists
    FROM GOVERNANCE.APPS.V_STREAMLIT_INVENTORY_LATEST
    WHERE FULL_NAME = :P_FULL_NAME;

    IF (v_exists = 0) THEN
        RETURN 'FAILED: ' || :P_FULL_NAME || ' not found in the latest audit. '
            || 'Run CALL GOVERNANCE.APPS.SP_AUDIT_STREAMLIT_APPS() first.';
    END IF;

    SELECT PROVENANCE, IS_LEGACY_SOURCE, IS_ADMIN_OWNED
      INTO v_provenance, v_legacy, v_admin_owned
    FROM GOVERNANCE.APPS.V_STREAMLIT_INVENTORY_LATEST
    WHERE FULL_NAME = :P_FULL_NAME;

    -- is it registered, and are the human commitments recorded?
    SELECT COUNT(*) INTO v_reg
    FROM GOVERNANCE.APPS.APP_REGISTRY
    WHERE FULL_NAME = :P_FULL_NAME;

    IF (v_reg = 0) THEN
        RETURN 'FAILED: no registry entry for ' || :P_FULL_NAME
            || '. Insert one with business owner and support group first.';
    END IF;

    SELECT BUSINESS_OWNER, SUPPORT_GROUP
      INTO v_biz_owner, v_support
    FROM GOVERNANCE.APPS.APP_REGISTRY
    WHERE FULL_NAME = :P_FULL_NAME;

    -- ---- mechanically verifiable checks ----
    IF (v_provenance = 'NONE') THEN
        v_failures := v_failures
            || '; no provenance (not Git-sourced and not DCM-managed)';
    END IF;

    IF (v_legacy) THEN
        v_failures := v_failures
            || '; legacy ROOT_LOCATION source model -- migrate to FROM first';
    END IF;

    IF (v_admin_owned) THEN
        -- Ownership cannot be transferred, so this cannot be fixed with a
        -- grant. The app has to be recreated under a functional role.
        v_failures := v_failures
            || '; owned by an admin role -- viewers would inherit admin rights. '
            || 'Ownership cannot be transferred; recreate under a functional role';
    END IF;

    IF (NULLIF(TRIM(COALESCE(v_biz_owner, '')), '') IS NULL) THEN
        v_failures := v_failures || '; registry has no BUSINESS_OWNER';
    END IF;

    IF (NULLIF(TRIM(COALESCE(v_support, '')), '') IS NULL) THEN
        v_failures := v_failures || '; registry has no SUPPORT_GROUP';
    END IF;

    IF (LENGTH(v_failures) > 0) THEN
        RETURN 'NOT CERTIFIED: ' || LTRIM(v_failures, '; ');
    END IF;

    -- ---- record certification ----
    UPDATE GOVERNANCE.APPS.APP_REGISTRY
       SET CERTIFICATION = 'CERTIFIED',
           CERTIFIED_BY  = :P_CERTIFIED_BY,
           CERTIFIED_ON  = CURRENT_DATE(),
           LAST_REVIEWED = CURRENT_DATE(),
           TIER          = 'CERTIFIED',
           UPDATED_ON    = CURRENT_TIMESTAMP()
     WHERE FULL_NAME = :P_FULL_NAME;

    -- ---- project onto the object as a tag ----
    -- Imperative because DCM ATTACH TAG does not support STREAMLIT. Non-fatal:
    -- the registry remains authoritative if the tag cannot be applied.
    BEGIN
        EXECUTE IMMEDIATE
            'ALTER STREAMLIT ' || :P_FULL_NAME
            || ' SET TAG GOVERNANCE.APPS.APP_LIFECYCLE = ''CERTIFIED''';

        EXECUTE IMMEDIATE
            'ALTER STREAMLIT ' || :P_FULL_NAME
            || ' SET TAG GOVERNANCE.APPS.APP_SUPPORT_GROUP = '''
            || REPLACE(v_support, '''', '''''') || '''';
    EXCEPTION
        WHEN OTHER THEN
            v_err := SQLSTATE || ' / ' || SQLERRM;
            RETURN 'CERTIFIED in registry, but tagging failed: ' || v_err
                || ' (registry is authoritative; apply the tag manually)';
    END;

    RETURN 'CERTIFIED: ' || :P_FULL_NAME || ' by ' || :P_CERTIFIED_BY
        || ' (provenance: ' || v_provenance || ', support: ' || v_support || ')';
END;
$$;


-- ============================================================================
-- Seed the reference app
-- ============================================================================
MERGE INTO GOVERNANCE.APPS.APP_REGISTRY t
USING (
    SELECT
        'FANATICS_MERCH_DEV.SERVE.MERCH_PERFORMANCE' AS FULL_NAME,
        'Merch Performance'                          AS TITLE,
        'League and channel merch performance: revenue, units, and return rates by team and sales channel.' AS DESCRIPTION,
        'Commerce'                                   AS DOMAIN,
        'Analyst'                                    AS PERSONA,
        'CERTIFIED'                                  AS TIER,
        'Luke Kranz'                                 AS BUSINESS_OWNER,
        'Rich Ecker'                                 AS TECHNICAL_OWNER,
        'DSEA Platform'                              AS SUPPORT_GROUP,
        'APP_MERCH_OWNER_DEV'                        AS OWNER_ROLE,
        'APP_MERCH_VIEWER_DEV'                       AS VIEWER_ROLE,
        'Internal'                                   AS DATA_CLASSIFICATION,
        'https://github.com/sfc-gh-recker/streamlit_work' AS SOURCE_REPO,
        'demo_app/streamlit/merch_performance'       AS SOURCE_PATH,
        'GOVERNANCE.PROJECTS.MERCH_PERFORMANCE_DEV'  AS DCM_PROJECT,
        'storefront'                                 AS ICON
) s
ON t.FULL_NAME = s.FULL_NAME
WHEN MATCHED THEN UPDATE SET
    TITLE = s.TITLE, DESCRIPTION = s.DESCRIPTION, DOMAIN = s.DOMAIN,
    PERSONA = s.PERSONA, TIER = s.TIER, BUSINESS_OWNER = s.BUSINESS_OWNER,
    TECHNICAL_OWNER = s.TECHNICAL_OWNER, SUPPORT_GROUP = s.SUPPORT_GROUP,
    OWNER_ROLE = s.OWNER_ROLE, VIEWER_ROLE = s.VIEWER_ROLE,
    DATA_CLASSIFICATION = s.DATA_CLASSIFICATION, SOURCE_REPO = s.SOURCE_REPO,
    SOURCE_PATH = s.SOURCE_PATH, DCM_PROJECT = s.DCM_PROJECT, ICON = s.ICON,
    UPDATED_ON = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT
    (FULL_NAME, TITLE, DESCRIPTION, DOMAIN, PERSONA, TIER, BUSINESS_OWNER,
     TECHNICAL_OWNER, SUPPORT_GROUP, OWNER_ROLE, VIEWER_ROLE,
     DATA_CLASSIFICATION, SOURCE_REPO, SOURCE_PATH, DCM_PROJECT, ICON,
     LAST_REVIEWED)
VALUES
    (s.FULL_NAME, s.TITLE, s.DESCRIPTION, s.DOMAIN, s.PERSONA, s.TIER,
     s.BUSINESS_OWNER, s.TECHNICAL_OWNER, s.SUPPORT_GROUP, s.OWNER_ROLE,
     s.VIEWER_ROLE, s.DATA_CLASSIFICATION, s.SOURCE_REPO, s.SOURCE_PATH,
     s.DCM_PROJECT, s.ICON, CURRENT_DATE());
