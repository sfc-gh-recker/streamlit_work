-- ============================================================================
-- Access control: functional owner and viewer roles
-- ============================================================================
-- The single most important governance decision for a Streamlit app is who
-- owns it, because SiS apps run with OWNER'S RIGHTS by default. Every viewer
-- reaches data through the owner role's privileges, not their own.
--
-- Consequences that follow from that, and why this file looks the way it does:
--
--   * A production app must NEVER be owned by an individual user. When they
--     change team the app either breaks or silently keeps their access.
--   * A production app must NEVER be owned by ACCOUNTADMIN or SYSADMIN. Doing
--     so hands admin-level reach to everyone who can open the dashboard. The
--     audit found 64 of 80 existing apps in this state.
--   * CURRENT_ROLE() inside the app returns the OWNER's role, not the
--     viewer's. Row access policies keyed on CURRENT_ROLE() therefore do not
--     segment viewers under owner's rights. If per-viewer segmentation is
--     required, use caller's rights instead and grant viewers data access
--     directly.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- Functional owner role -- the app runs as this
-- ----------------------------------------------------------------------------
DEFINE ROLE APP_MERCH_OWNER{{ env_suffix }}
    COMMENT = 'Functional owner of the Merch Performance app. Determines what viewers can reach.';

-- Least privilege: the owner role reads the serving view and nothing else.
-- It deliberately has no access to CORE, so a bug in the app cannot expose
-- base tables.
GRANT USAGE ON DATABASE FANATICS_MERCH{{ env_suffix }}
    TO ROLE APP_MERCH_OWNER{{ env_suffix }};
GRANT USAGE ON SCHEMA FANATICS_MERCH{{ env_suffix }}.SERVE
    TO ROLE APP_MERCH_OWNER{{ env_suffix }};
GRANT SELECT ON VIEW FANATICS_MERCH{{ env_suffix }}.SERVE.V_MERCH_PERFORMANCE
    TO ROLE APP_MERCH_OWNER{{ env_suffix }};
GRANT USAGE ON WAREHOUSE {{ warehouse }}
    TO ROLE APP_MERCH_OWNER{{ env_suffix }};
-- Container runtime: the owner role needs the compute pool too, not just the
-- warehouse. Omitting this is a common cause of an app that deploys cleanly and
-- then fails to start.
GRANT USAGE ON COMPUTE POOL SYSTEM_COMPUTE_POOL_CPU
    TO ROLE APP_MERCH_OWNER{{ env_suffix }};


-- ----------------------------------------------------------------------------
-- Viewer role -- business users who open the dashboard
-- ----------------------------------------------------------------------------
-- Viewers need USAGE on the database, the schema, and the Streamlit object.
-- They need NO grants on the underlying data, because the app reads it as the
-- owner role. That is the main ergonomic benefit of owner's rights and why it
-- is the right default for a reporting dashboard.
DEFINE ROLE APP_MERCH_VIEWER{{ env_suffix }}
    COMMENT = 'Business viewers of the Merch Performance app. No direct data grants.';

GRANT USAGE ON DATABASE FANATICS_MERCH{{ env_suffix }}
    TO ROLE APP_MERCH_VIEWER{{ env_suffix }};
GRANT USAGE ON SCHEMA FANATICS_MERCH{{ env_suffix }}.SERVE
    TO ROLE APP_MERCH_VIEWER{{ env_suffix }};
GRANT USAGE ON STREAMLIT FANATICS_MERCH{{ env_suffix }}.SERVE.MERCH_PERFORMANCE
    TO ROLE APP_MERCH_VIEWER{{ env_suffix }};
GRANT USAGE ON WAREHOUSE {{ warehouse }}
    TO ROLE APP_MERCH_VIEWER{{ env_suffix }};


-- ----------------------------------------------------------------------------
-- Developer role -- self-service without admin rights
-- ----------------------------------------------------------------------------
-- This is the concrete unblock for "non-admin users cannot create apps".
-- Nothing here requires ACCOUNTADMIN.
--
-- Deliberately NOT granted:
--   CREATE STAGE  -- only needed for the legacy ROOT_LOCATION source model.
--                    On the FROM model the app uses an embedded stage, so this
--                    grant is unnecessary. If your users are blocked on stage
--                    creation, migrating to FROM removes the blocker rather
--                    than requiring a new privilege.
--   CREATE STREAM -- only needed if the app itself creates or reads streams.
--                    Add it per-app if genuinely required; do not put it in the
--                    baseline developer role.
DEFINE ROLE SIS_DEVELOPER{{ env_suffix }}
    COMMENT = 'Streamlit developers. Can build and deploy apps without admin privileges.';

GRANT USAGE ON DATABASE FANATICS_MERCH{{ env_suffix }}
    TO ROLE SIS_DEVELOPER{{ env_suffix }};
GRANT USAGE ON SCHEMA FANATICS_MERCH{{ env_suffix }}.SERVE
    TO ROLE SIS_DEVELOPER{{ env_suffix }};
GRANT CREATE STREAMLIT ON SCHEMA FANATICS_MERCH{{ env_suffix }}.SERVE
    TO ROLE SIS_DEVELOPER{{ env_suffix }};
GRANT SELECT ON VIEW FANATICS_MERCH{{ env_suffix }}.SERVE.V_MERCH_PERFORMANCE
    TO ROLE SIS_DEVELOPER{{ env_suffix }};
GRANT USAGE ON WAREHOUSE {{ warehouse }}
    TO ROLE SIS_DEVELOPER{{ env_suffix }};


-- ----------------------------------------------------------------------------
-- Ownership: the deploying role IS the owner. There is no transfer.
-- ----------------------------------------------------------------------------
-- VERIFIED LIMITATION, and it shapes the whole pattern:
--
--   1. DCM Projects rejects `GRANT OWNERSHIP ON STREAMLIT` outright:
--        "Unsupported feature GRANT/REVOKE OWNERSHIP ON STREAMLIT"
--      (observed during PLAN: 23 of 24 statements succeeded, this one failed)
--
--   2. STREAMLIT is not in the supported object_type list for GRANT OWNERSHIP
--      in SQL either. So there is no imperative post-deploy fix and no
--      ALTER STREAMLIT ... SET OWNER equivalent.
--
-- Streamlit ownership therefore cannot be reassigned after creation. Per the
-- owner's-rights documentation, "when an app is created, it runs with the role
-- of the user who originally created the app" -- and that is permanent.
--
-- CONSEQUENCE FOR THE PATTERN
-- The role that deploys the app is the role the app runs as, forever. So the
-- functional owner role must be the DEPLOYING role, configured as
-- project_owner on the target in manifest.yml:
--
--     prod:
--       project_owner: APP_DEPLOYER_PROD
--
-- and APP_DEPLOYER_PROD must hold exactly the data privileges the app should
-- expose to viewers -- no more. Granting that role to the CI/CD service user
-- and never to individual developers is what keeps production immutable.
--
-- CONSEQUENCE FOR REMEDIATION
-- An existing app owned by ACCOUNTADMIN cannot be re-owned. It has to be
-- RECREATED under the correct role. For the 64 admin-owned apps the audit
-- found, that is the actual remediation path -- redeploy, not re-grant. Worth
-- being blunt about this with anyone who assumes it is a one-line fix.
--
-- APP_MERCH_OWNER below is therefore defined and privileged so it is ready to
-- be used as a deploying role, but no ownership transfer is attempted here.
GRANT ROLE APP_MERCH_OWNER{{ env_suffix }} TO ROLE SYSADMIN;
