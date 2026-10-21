-- ============================================================================
-- Duplicate App Pre-flight
-- ============================================================================
-- Run this BEFORE creating a new Streamlit app. An estate grows by accretion:
-- nobody sets out to build the third returns dashboard, they just can't see the
-- first two. This answers "does something like this already exist?" in the one
-- window where the answer is cheap to act on.
--
-- WHY IT READS `SHOW STREAMLITS` AND NOT THE GOVERNANCE INVENTORY
-- The duplicate gate is needed from the very first app -- before the audit
-- procedure, the registry, or any of the practice exists. So the baseline
-- signal has to be something every account has on day zero. The inventory and
-- registry are joined in as ENRICHMENT when present (see the LEFT JOINs), which
-- means this file works unchanged in a greenfield account and gets sharper as
-- the practice matures.
--
-- MATCHING MODEL
-- Two signals, deliberately combined, because each alone produces garbage:
--
--   token overlap   Shared domain words after stripping generic noise
--                   ('DASHBOARD', 'REPORT', 'V', 'DEMO'...). This is the
--                   high-precision signal -- two apps both containing RETURNS
--                   and MARGIN are almost certainly related.
--
--   Jaro-Winkler    Catches typo-level and suffix variants that token overlap
--                   misses: SALES_PERFORMANCE vs SALES_PERFORMANCE_OWNED.
--                   On its own it is near-useless at this scale -- measured
--                   against a 91-app estate, "Classification Example" scores
--                   68 against "Sales Performance". Hence the 85 floor when
--                   there is no token overlap to corroborate it.
--
-- A high score on BOTH is near-identical. Token overlap alone is a likely
-- duplicate. Everything below that threshold is suppressed rather than shown,
-- because a gate that cries wolf gets clicked through.
--
-- MACHINE-NAMED APPS
-- Apps created through Snowsight's workspace preview get names like
-- ST4A27C91BEA... with title 'Untitled'. Those cannot be matched on name at
-- all, and in a sprawling estate they are a large share of the population --
-- so the summary reports how many are unmatchable instead of silently
-- pretending the search was exhaustive.
--
-- USAGE (identifier fragments are passed UNQUOTED -- snow sql does not strip
-- quotes, so --variable "app_name='X'" renders the quotes into the SQL):
--
--   snow sql -f audit/duplicate_check.sql --enable-templating JINJA \
--     --variable "app_name=RETURNS_PERFORMANCE" \
--     --variable "app_title=Returns Performance" \
--     --variable "data_source=RETAIL.SERVE.V_RETURNS"
--
-- Set data_source to '' if the backing view is not yet decided.
-- ============================================================================

SET cand_name   = '{{ app_name }}';
SET cand_title  = '{{ app_title }}';
SET cand_source = '{{ data_source }}';

SHOW STREAMLITS IN ACCOUNT;

-- Capture the id rather than relying on LAST_QUERY_ID() at each use site. The
-- app list is needed by two queries below, and LAST_QUERY_ID() only refers to
-- the immediately preceding statement -- the second use would silently scan the
-- first query's output. A temp table would also work but requires a current
-- database, which a day-zero account may not have set.
SET apps_qid = LAST_QUERY_ID();

-- ----------------------------------------------------------------------------
-- Ranked matches
-- ----------------------------------------------------------------------------
WITH _dup_candidates AS (
    SELECT "database_name"||'.'||"schema_name"||'.'||"name" AS full_name,
           "name"                     AS app_name,
           COALESCE("title",'')       AS app_title,
           "owner"                    AS app_owner,
           "created_on"::DATE         AS created_on,
           "url_id"                   AS url_id
      FROM TABLE(RESULT_SCAN($apps_qid))
), stop AS (
    SELECT ARRAY_CONSTRUCT('APP','APPS','DASHBOARD','DASHBOARDS','REPORT',
           'REPORTING','ANALYSIS','ANALYTICS','DATA','VIEW','V','MY','TEST',
           'DEMO','NEW','FINAL','COPY','PROD','DEV','UAT','STREAMLIT','THE',
           'AND','FOR','OF','SIS','UNTITLED','') AS w
), scored AS (
    SELECT c.full_name, c.app_title, c.app_owner, c.created_on, c.url_id,
           JAROWINKLER_SIMILARITY(UPPER(c.app_name), UPPER($cand_name))
               AS name_score,
           CASE WHEN c.app_title = '' THEN NULL
                ELSE JAROWINKLER_SIMILARITY(UPPER(c.app_title),
                                            UPPER($cand_title))
           END AS title_score,
           -- ARRAY_DISTINCT: name and title usually repeat the same tokens, and
           -- an undeduplicated count double-reports the strength of the match.
           ARRAY_DISTINCT(ARRAY_INTERSECTION(
               ARRAY_EXCEPT(SPLIT(UPPER(REPLACE(
                   c.app_name||' '||c.app_title,'_',' ')),' '), s.w),
               ARRAY_EXCEPT(SPLIT(UPPER(REPLACE(
                   $cand_name||' '||$cand_title,'_',' ')),' '), s.w)
           )) AS matched_on
      FROM _dup_candidates c CROSS JOIN stop s
)
SELECT full_name,
       NULLIF(app_title,'')                AS title,
       app_owner                           AS owner,
       created_on,
       ROUND(name_score)                   AS name_pct,
       ROUND(title_score)                  AS title_pct,
       ARRAY_SIZE(matched_on)              AS shared_tokens,
       matched_on,
       CASE
           WHEN name_score >= 90 OR title_score >= 90 THEN 'NEAR-IDENTICAL'
           WHEN ARRAY_SIZE(matched_on) >= 2           THEN 'LIKELY DUPLICATE'
           ELSE 'POSSIBLE OVERLAP'
       END                                 AS verdict
  FROM scored
 -- Suppression, not ranking. Token overlap is trustworthy on its own; a raw
 -- similarity score is only admissible above 85, where it stops being noise.
 WHERE ARRAY_SIZE(matched_on) >= 1
    OR name_score  >= 85
    OR title_score >= 85
 ORDER BY CASE verdict WHEN 'NEAR-IDENTICAL'   THEN 1
                       WHEN 'LIKELY DUPLICATE' THEN 2
                       ELSE 3 END,
          ARRAY_SIZE(matched_on) DESC,
          GREATEST(COALESCE(name_score,0), COALESCE(title_score,0)) DESC
 LIMIT 25;

-- ----------------------------------------------------------------------------
-- Same-data check
-- ----------------------------------------------------------------------------
-- Name matching misses the most expensive kind of duplicate: a differently
-- named app built on the same view. If the registry exists it already records
-- each app's declared source, making this a direct lookup rather than a guess.
--
-- The statement is built as text and run through EXECUTE IMMEDIATE so that
-- compilation is deferred to runtime. Referencing the registry table directly
-- would fail at COMPILE time on a greenfield account -- before any EXCEPTION
-- handler can run -- which would make this whole file unusable precisely when
-- the duplicate gate matters most: on the first app, before the practice is
-- stood up.
EXECUTE IMMEDIATE $$
DECLARE
    rs   RESULTSET;
    stmt VARCHAR;
BEGIN
    IF ($cand_source = '') THEN
        rs := (SELECT 'no data source supplied - same-data check skipped'
                      AS note);
        RETURN TABLE(rs);
    END IF;
    stmt := 'SELECT FULL_NAME, TITLE, DOMAIN, PERSONA, TIER,
                    BUSINESS_OWNER, CERTIFICATION
               FROM GOVERNANCE.APPS.APP_REGISTRY
              WHERE UPPER(SOURCE_PATH)  LIKE ''%' || UPPER($cand_source) || '%''
                 OR UPPER(DESCRIPTION)  LIKE ''%' || UPPER($cand_source) || '%''';
    rs := (EXECUTE IMMEDIATE :stmt);
    RETURN TABLE(rs);
EXCEPTION
    WHEN OTHER THEN
        rs := (SELECT 'registry not deployed yet - same-data check skipped'
                      AS note);
        RETURN TABLE(rs);
END;
$$;

-- ----------------------------------------------------------------------------
-- Search coverage
-- ----------------------------------------------------------------------------
-- State plainly how much of the estate name matching could not see, so the
-- result is read as "no name collision" rather than "no duplicate exists".
SELECT COUNT(*)                                              AS apps_searched,
       COUNT_IF(COALESCE("title",'') IN ('','Untitled'))      AS no_title,
       COUNT_IF(REGEXP_LIKE("name",'^(ST)?[A-Z0-9]{16,}$'))   AS machine_named,
       COUNT_IF(REGEXP_LIKE("name",'^(ST)?[A-Z0-9]{16,}$')
                AND COALESCE("title",'') IN ('','Untitled'))  AS unmatchable
  FROM TABLE(RESULT_SCAN($apps_qid));
