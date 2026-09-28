-- ============================================================================
-- DEMO 2 -- The Git round trip, run live
--
-- Demo 1 proves provenance exists and that most apps do not have it. This one
-- proves the loop actually closes: an edit in the repository becomes a new
-- deployed version, and the account can name the commit it came from.
--
-- This is the beat that answers "why did the analysts leave Sigma" -- the
-- answer is a reviewable diff and a rollback target, not a nicer chart.
--
-- RUN ORDER matters. Steps 1-2 happen in a terminal, the rest in Snowflake.
-- Budget about 8 minutes. Everything here was executed end to end on
-- 2026-09-28, and the recorded outputs below are real.
--
-- PREREQUISITES
--   GOVERNANCE.PROJECTS.STREAMLIT_WORK_REPO   Git repository object
--   GOVERNANCE.PROJECTS.MERCH_PERFORMANCE_DEV DCM project object
--   A warehouse. The audit and the FETCH both need compute.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- STEP 1 (terminal) -- Make a visible change and push it
-- ----------------------------------------------------------------------------
-- Edit demo_app/streamlit/merch_performance/streamlit_app.py, then:
--
--   git add -A
--   git commit -m "Add provenance footer"
--   git push origin main
--
-- Do this in the room. The point lands better when the audience watches an
-- ordinary commit become a governed deployment, rather than being shown a
-- deployment that already happened.


-- ----------------------------------------------------------------------------
-- STEP 2 (terminal, optional but recommended) -- Tag the release
-- ----------------------------------------------------------------------------
--   git tag -a v0.1.0 -m "Reference app release"
--   git push origin v0.1.0
--
-- Tagging is what makes the Certified tier meaningful. See step 6 for why the
-- tag has to be consumed through DCM rather than by the Streamlit commands.


-- ----------------------------------------------------------------------------
-- BEAT 1 -- Snowflake does not see the change until it is told to look
-- ----------------------------------------------------------------------------
-- FETCH is explicit. That is a feature: nothing in the account moves because
-- someone pushed to a branch.
ALTER GIT REPOSITORY GOVERNANCE.PROJECTS.STREAMLIT_WORK_REPO FETCH;

-- Live result:
--   Branch | main   | FAST_FORWARD
--   Tag    | v0.1.0 | NEW

SHOW GIT BRANCHES IN GOVERNANCE.PROJECTS.STREAMLIT_WORK_REPO;
SHOW GIT TAGS     IN GOVERNANCE.PROJECTS.STREAMLIT_WORK_REPO;

-- Live result:
--   main   | /branches/main | 1628c7bfca13f970aca0c9e53de3a50070de6ee3
--   v0.1.0 | /tags/v0.1.0   | 1628c7bfca13f970aca0c9e53de3a50070de6ee3
--
-- The tag and the branch head agree, because the tag was cut from this commit.
-- SHOW GIT TAGS resolving a tag to a SHA is what makes tag-based deployment
-- auditable later -- see beat 5.


-- ----------------------------------------------------------------------------
-- BEAT 2 -- The repository files are now addressable as a stage
-- ----------------------------------------------------------------------------
LIST @GOVERNANCE.PROJECTS.STREAMLIT_WORK_REPO/branches/main/demo_app/;

-- Two things to point out in the output:
--   utils/config.py and utils/data.py kept their directory. Package structure
--     survived, which is the thing that breaks if an asset path is listed
--     explicitly instead of globbed.
--   No __pycache__. Bytecode is cleaned before commit; a ** glob has no
--     negation, so anything present would have shipped.


-- ----------------------------------------------------------------------------
-- BEAT 3 -- PLAN first. Always.
-- ----------------------------------------------------------------------------
-- Deploy from the TAG, not from branches/main. Beat 5 explains why.
EXECUTE DCM PROJECT GOVERNANCE.PROJECTS.MERCH_PERFORMANCE_DEV
    PLAN
    USING CONFIGURATION DEV
    FROM '@GOVERNANCE.PROJECTS.STREAMLIT_WORK_REPO/tags/v0.1.0/demo_app/';

-- The result is a VARIANT, so unpack it to read the changeset:
SELECT TO_VARCHAR("result") AS plan_json
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

-- Live result, trimmed to the part that matters:
--   "changeset": [{
--       "type": "ALTER",
--       "object_id": { "domain": "STREAMLIT",
--                      "fqn": "FANATICS_MERCH_DEV.SERVE.MERCH_PERFORMANCE" },
--       "changes": [{ "attribute_name": "default_version_name",
--                     "kind": "changed",
--                     "prev_value": "VERSION$3", "value": "VERSION$4" }]
--   }]
--
-- ONE change. A Python-only edit produced a single reviewable ALTER: the app
-- gets a new version and nothing else in the environment is touched. The
-- database, schemas, table, view and roles are all declared in the same
-- project and all correctly no-ops.
--
-- This is the moment to make the Sigma comparison explicit. The question
-- "what is about to change in production, and who approved it" has a literal
-- answer here, before anything is applied.


-- ----------------------------------------------------------------------------
-- BEAT 4 -- Deploy, with the release in the alias
-- ----------------------------------------------------------------------------
-- The alias is the deployment's commit message. Put the tag or SHA in it: it
-- is the first field a human reads in the history, and it is the only one
-- written by a person rather than derived.
EXECUTE DCM PROJECT GOVERNANCE.PROJECTS.MERCH_PERFORMANCE_DEV
    DEPLOY AS "release-v0.1.0"
    USING CONFIGURATION DEV
    FROM '@GOVERNANCE.PROJECTS.STREAMLIT_WORK_REPO/tags/v0.1.0/demo_app/';


-- ----------------------------------------------------------------------------
-- BEAT 5 -- The deployment history, and the trap inside it
-- ----------------------------------------------------------------------------
SHOW DEPLOYMENTS IN DCM PROJECT GOVERNANCE.PROJECTS.MERCH_PERFORMANCE_DEV;

-- Live result, oldest last. Read the source_file_path column top to bottom --
-- it is a ladder of provenance quality:
--
--   $6 release-v0.1.0                @...REPO/tags/v0.1.0/demo_app/
--   $5 git-1628c7b-provenance-footer @...REPO/commits/1628c7bf…/demo_app/
--   $4 git-d2915be-pinned-commit-path @...REPO/commits/d2915be1…/demo_app/
--   $3 (no alias)                    @...REPO/branches/main/demo_app/
--   $2 container-runtime-fix         @...DCM_…_TMP_STAGE
--   $1 initial-f3641ef               @...DCM_…_TMP_STAGE
--
--   $1, $2  deployed from a local directory. No Git trace whatsoever.
--   $3      deployed from a BRANCH. Git, but a moving pointer -- six months
--           from now nothing here tells you which commit shipped.
--   $4, $5  deployed from a pinned COMMIT. Immutable and auditable.
--   $6      deployed from a TAG. Auditable, and it also carries intent:
--           a human decided this was a release.
--
-- THE TRAP: that output has a git_commit_hash column, and it is EMPTY on every
-- row -- including the rows deployed from a fully pinned commit path. It is
-- documented as recording the originating commit; it does not populate.
-- Verified against 10.34.101.
--
-- So the FROM path is not a style preference. It is the entire audit trail.
-- That is why beats 3 and 4 deploy from a tag.


-- ----------------------------------------------------------------------------
-- BEAT 6 -- Why the tag had to go through DCM
-- ----------------------------------------------------------------------------
-- The two ways to deploy a Streamlit accept OPPOSITE path forms. This is worth
-- showing live, because the failure is not obvious from the documentation --
-- ALTER STREAMLIT explicitly documents FROM { <snowgit_tag_uri> |
-- <snowgit_commit_uri> }, and neither of those works.

-- Rejected -- "Invalid git branch path: tags/v0.1.0/…"
ALTER STREAMLIT GOVERNANCE.APPS.MERCH_PERFORMANCE_GITDIRECT
    ADD VERSION "rel_v0_1_0"
    FROM '@GOVERNANCE.PROJECTS.STREAMLIT_WORK_REPO/tags/v0.1.0/demo_app/streamlit/merch_performance/';

-- Also rejected, at any depth, including the bare commit root.
ALTER STREAMLIT GOVERNANCE.APPS.MERCH_PERFORMANCE_GITDIRECT
    ADD VERSION "by_commit"
    FROM '@GOVERNANCE.PROJECTS.STREAMLIT_WORK_REPO/commits/1628c7bfca13f970aca0c9e53de3a50070de6ee3/demo_app/streamlit/merch_performance/';

-- Accepted. Only branches/ works for the Streamlit commands.
ALTER STREAMLIT GOVERNANCE.APPS.MERCH_PERFORMANCE_GITDIRECT
    ADD VERSION "provenance_footer"
    FROM '@GOVERNANCE.PROJECTS.STREAMLIT_WORK_REPO/branches/main/demo_app/streamlit/merch_performance/'
    COMMENT = 'Branch path resolves to a concrete commit at add time';

--   EXECUTE DCM PROJECT … FROM        branches/  commits/  tags/     all work
--   CREATE STREAMLIT … FROM           branches/ only
--   ALTER STREAMLIT ADD VERSION FROM  branches/ only
--
-- The consequence for the three-tier model: a Certified app pinned to an
-- immutable release tag MUST be deployed by DCM. Tag-pinned deployment is not
-- reachable from CREATE STREAMLIT or ADD VERSION at all.
--
-- Auditability is not lost on the branch path, though, which is the saving
-- grace -- see beat 7.


-- ----------------------------------------------------------------------------
-- BEAT 7 -- The best provenance artifact in the product
-- ----------------------------------------------------------------------------
SHOW VERSIONS IN STREAMLIT GOVERNANCE.APPS.MERCH_PERFORMANCE_GITDIRECT;

-- Live result:
--   VERSION$3 | provenance_footer | is_default | 1628c7bfca13f970aca0c9e53de3a50070de6ee3
--   VERSION$2 | v_branch_test     |            | 1628c7bfca13f970aca0c9e53de3a50070de6ee3
--   VERSION$1 |                   |            | d2915be1f45bb9fabc419011f71369861d833122
--
-- Every version carries the commit it was built from. Three points to make:
--
--   1. The branch path was resolved to a CONCRETE commit and frozen at add
--      time. The app does not drift when the branch moves. That is why
--      branches/ is safe here but not for DCM.
--   2. VERSION$1 is still present and still addressable. This is the rollback
--      target, and ADD VERSION is non-destructive -- unlike
--      CREATE OR REPLACE STREAMLIT, which drops the app's grants.
--   3. VERSION$2 and VERSION$3 share a commit, because they were added from
--      the same unchanged branch state. Provenance is content-addressed, not
--      sequence-addressed.
--
-- For the "which version is live and how do I get back" conversation, this
-- single command is a better answer than anything DCM exposes.


-- ----------------------------------------------------------------------------
-- BEAT 8 -- Close the loop: the audit reclassifies automatically
-- ----------------------------------------------------------------------------
CALL GOVERNANCE.APPS.SP_AUDIT_STREAMLIT_APPS();

SELECT APP_NAME,
       PROVENANCE,
       COALESCE(DCM_SOURCE_REF, '-')   AS ref_type,
       SUBSTR(COMMIT_SHA, 1, 12)       AS commit_sha,
       IS_UNPINNED_SOURCE              AS not_traceable,
       TIER
FROM GOVERNANCE.APPS.V_STREAMLIT_INVENTORY_LATEST
WHERE PROVENANCE <> 'NONE'
ORDER BY PROVENANCE, APP_NAME;

-- Live result:
--   MERCH_PERFORMANCE           | DCM_MANAGED | TAG | 1628c7bfca13 | FALSE | CERTIFIED
--   CORTEX_AGENT_CHAT_APP       | GIT_DIRECT  | -   | 15e3e34e80cd | FALSE | CERTIFIED
--   MERCH_PERFORMANCE_GITDIRECT | GIT_DIRECT  | -   | 1628c7bfca13 | FALSE | CERTIFIED
--
-- The two apps built from this repository report the SAME commit by two
-- completely different mechanisms:
--
--   MERCH_PERFORMANCE_GITDIRECT  read from the app object's own commit hash
--   MERCH_PERFORMANCE            recovered from the DCM deployment's
--                                source_file_path -> tag -> SHOW GIT TAGS
--
-- Nobody typed either value. That is the whole argument: provenance is a
-- byproduct of how the app was deployed, so it cannot be faked, forgotten, or
-- argued with in a review meeting.
--
-- Contrast with the rest of the estate:
SELECT TOTAL_APPS, NO_PROVENANCE, PCT_UNGOVERNED,
       TRACEABLE_TO_COMMIT, GOVERNED_NOT_TRACEABLE
FROM GOVERNANCE.APPS.V_STREAMLIT_SPRAWL_SUMMARY;

-- Live result: 85 apps, 82 with no provenance (96.5%), 3 traceable to a commit.
--
-- The three traceable apps are the two built here plus one pre-existing app
-- someone had already done correctly. Everything else is unattributable, and
-- that is the support load the DSEA team is absorbing today.
