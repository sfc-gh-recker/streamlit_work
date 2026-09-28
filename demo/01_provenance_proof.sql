-- ============================================================================
-- The 60-Second Git Provenance Proof
-- ============================================================================
-- Purpose: establish, in under a minute and with no setup, that Snowflake
-- records Git provenance on a deployed Streamlit app -- and that this gives
-- you a binary, un-fakeable test for whether an app is governed.
--
-- Everything here is READ-ONLY. It works under a restricted session scope and
-- needs no repository, no integration, and no deployment. Use this as the
-- opening beat of the session, and as the fallback if the live end-to-end
-- deployment (demo/02_git_deploy.sh) cannot be run.
--
-- All output below was captured live on account XOB85174 on 2026-09-28.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- BEAT 1 -- A governed app. Where did this code come from?
-- ----------------------------------------------------------------------------
DESCRIBE STREAMLIT CORTEX_AGENTS_DEMO.PUBLIC.CORTEX_AGENT_CHAT_APP;

-- Look at three columns in the output:
--
--   default_version_source_location_uri
--     @CORTEX_AGENTS_DEMO.PUBLIC.GITHUB_REPO_CORTEX_AGENTS_DEMO/branches/main/agent_app/
--
--   default_version_git_commit_hash
--     15e3e34e80cdc1e8d64b34a1d0b8ad206d002c1b
--
--   live_version_location_uri
--     snow://streamlit/CORTEX_AGENTS_DEMO.PUBLIC.CORTEX_AGENT_CHAT_APP/versions/live/
--
-- Snowflake is telling you the repository, the branch, and the exact commit
-- this running app was built from. You can go to that commit in GitHub and
-- read the diff that produced what your users are looking at right now.
--
-- Nobody typed that hash in. It is not a tag, a naming convention, or a wiki
-- entry someone has to remember to update. It is recorded by the deployment
-- mechanism itself, which means it cannot be backfilled by an app that did
-- not come from a repository.


-- ----------------------------------------------------------------------------
-- BEAT 2 -- An ungoverned app. Same question.
-- ----------------------------------------------------------------------------
DESCRIBE STREAMLIT AMBIENT_AGENTS_DB.PUBLIC.BARE_MINIMUM;

-- This returns only 13 columns. There is no git_commit_hash column at all,
-- and no live_version_location_uri. What it has instead is:
--
--   root_location    @AMBIENT_AGENTS_DB.PUBLIC.STREAMLIT_STAGE
--
-- Two separate problems, and it is worth being precise about which is which:
--
--   1. No provenance. There is no commit, so there is no review, no diff, and
--      no way to reproduce this app or reason about what changed when it
--      breaks. Someone clicked around in Snowsight.
--
--   2. Legacy source model. root_location is the deprecated way of pointing a
--      Streamlit app at its files. Apps built this way CANNOT use Git
--      integration, CANNOT run on the container runtime, and CANNOT be edited
--      as multiple files in Snowsight. This one is not a process failure --
--      it is a hard technical ceiling. Such an app has to be migrated to the
--      FROM source model before any Git workflow is even possible.


-- ----------------------------------------------------------------------------
-- BEAT 3 -- Now the same question across the whole account.
-- ----------------------------------------------------------------------------
-- Requires audit/streamlit_inventory.sql to have been deployed and run.
SELECT
    TOTAL_APPS              AS "Apps",
    NO_GIT_PROVENANCE       AS "No provenance",
    PCT_UNGOVERNED          AS "% ungoverned",
    LEGACY_SOURCE_MODEL     AS "Legacy source model",
    ADMIN_OWNED             AS "Admin-owned",
    VERSION_UNPINNED        AS "Version unpinned",
    TIER_CERTIFIED          AS "Certified"
FROM GOVERNANCE.APPS.V_STREAMLIT_SPRAWL_SUMMARY;

-- Live result from this account:
--
--   Apps                  80
--   No provenance         79
--   % ungoverned          98.8
--   Legacy source model   60
--   Admin-owned           64
--   Version unpinned      80
--   Certified              1
--
-- One app out of eighty can prove where it came from.
--
-- Three of these numbers deserve to be said out loud:
--
--   79 of 80 have no provenance. If any of these breaks, there is no diff to
--   read and no commit to roll back to. That is the support-load problem
--   stated precisely: data engineering is being asked to fix things that have
--   no history.
--
--   60 of 80 are on the legacy source model. This is the one that changes
--   sequencing. Three quarters of the estate cannot adopt a Git workflow
--   without being migrated first. Any plan that assumes "just start using
--   Git" is understating the work by the size of that number.
--
--   80 of 80 have no exact Streamlit version pin. Range pins such as
--   streamlit>=1.39.0 silently do not take effect on the warehouse runtime
--   (SNOW-3601653). Every one of these apps can change behaviour underneath
--   its owner without a single line of code being edited. This is not
--   hypothetical: it is the class of problem behind the filter-state bug on
--   the Fanatics app in September, which reproduced on deployed SiS but not
--   on local Streamlit 1.50.


-- ----------------------------------------------------------------------------
-- BEAT 4 -- The governance query itself
-- ----------------------------------------------------------------------------
-- The one-line test that separates a sanctioned app from a side project.
-- This is the promotion gate, and the boundary of what data engineering
-- agrees to support.
SELECT
    FULL_NAME,
    TIER,
    OWNER_ROLE,
    SOURCE_MODEL,
    COALESCE(GIT_BRANCH, '--')                AS BRANCH,
    COALESCE(LEFT(GIT_COMMIT_HASH, 12), '--') AS COMMIT,
    FINDINGS
FROM GOVERNANCE.APPS.V_STREAMLIT_INVENTORY_LATEST
ORDER BY
    IFF(GIT_COMMIT_HASH IS NOT NULL, 0, 1),
    TIER,
    FULL_NAME
LIMIT 15;

-- Read it as: GIT_COMMIT_HASH IS NOT NULL is the whole gate.
--   present -> reviewed, reproducible, supportable, belongs in the catalog
--   absent  -> the owner supports it, not the platform team
--
-- The value of expressing the boundary this way is that it removes the
-- argument. It is not a judgement about whether an app looks important. It is
-- a column value that either exists or does not, and everyone can run the
-- query themselves.


-- ----------------------------------------------------------------------------
-- BEAT 5 (optional) -- Worth showing if the room pushes back
-- ----------------------------------------------------------------------------
-- The apps that cannot be inspected at all. An app you cannot describe is
-- still your problem when it breaks, so the audit records it rather than
-- dropping the row.
SELECT FULL_NAME, TIER, DESCRIBE_ERROR
FROM GOVERNANCE.APPS.V_STREAMLIT_INVENTORY_LATEST
WHERE DESCRIBE_ERROR IS NOT NULL;

-- Live result:
--   TRUAUDIENCE_IDENTITY_RESOLUTION_AND_ENRICHMENT.SHARE_SCHEMA.TAP_CONFIGURATION
--   22000 / Listing trial time limit exceeded.
--
-- A Streamlit app arriving via an expired listing trial. Not the headline
-- finding, but a useful illustration that the estate contains apps nobody on
-- the team provisioned or can currently open.
