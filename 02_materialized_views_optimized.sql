-- ============================================
-- OPTIMIZED Materialized Views
-- Alternative versions with performance improvements
-- ============================================

-- NOTE: These are OPTIMIZED versions addressing performance concerns.
-- Compare with 02_materialized_views.sql and choose based on your needs.

-- ============================================
-- OPTIMIZATION 1: Eliminate COALESCE in GROUP BY
-- ============================================
-- Assumes domain_category is always populated in ETL (denormalized)
-- This allows better sort key usage

-- Optimized mv_domain_usage_stats
CREATE MATERIALIZED VIEW mv_domain_usage_stats_opt
BACKUP NO
AUTO REFRESH YES
AS
SELECT 
    wa.domain_category,  -- No COALESCE - assumes populated in ETL
    dc.intent_type,
    wa.domain_name,
    DATE(wa.event_timestamp) AS event_date,
    wa.action_type,
    COUNT(*) AS action_count,
    COUNT(DISTINCT wa.thread_id) AS unique_threads,
    COUNT(DISTINCT wa.session_id) AS unique_sessions
FROM web_automations wa
LEFT JOIN domain_classifications dc ON wa.domain_name = dc.domain_name 
    AND dc.is_active = TRUE
WHERE wa.domain_category IS NOT NULL
GROUP BY 
    wa.domain_category,
    dc.intent_type,
    wa.domain_name,
    DATE(wa.event_timestamp),
    wa.action_type;

COMMENT ON MATERIALIZED VIEW mv_domain_usage_stats_opt IS 'Optimized domain stats - assumes domain_category populated in ETL';

-- ============================================
-- OPTIMIZATION 2: Eliminate Subquery in Materialized View
-- ============================================
-- Assumes result_count is calculated and stored in web_searches table

-- Optimized mv_web_search_statistics
CREATE MATERIALIZED VIEW mv_web_search_statistics_opt
BACKUP NO
AUTO REFRESH YES
AS
SELECT 
    DATE(ws.event_timestamp) AS event_date,
    ws.search_type,
    COUNT(*) AS search_count,
    COUNT(DISTINCT ws.thread_id) AS unique_threads,
    COUNT(DISTINCT ws.session_id) AS unique_sessions,
    AVG(ws.num_results) AS avg_results_per_search,
    SUM(COALESCE(ws.result_count, 0)) AS total_results_returned
FROM web_searches ws
WHERE ws.result_count IS NOT NULL OR ws.num_results IS NOT NULL
GROUP BY DATE(ws.event_timestamp), ws.search_type;

COMMENT ON MATERIALIZED VIEW mv_web_search_statistics_opt IS 'Optimized search stats - requires result_count column in web_searches';

-- ============================================
-- OPTIMIZATION 3: Add event_date Column Strategy
-- ============================================
-- If you add event_date as generated column, use this version

-- Optimized mv_basic_statistics (if event_date column exists)
CREATE MATERIALIZED VIEW mv_basic_statistics_opt
BACKUP NO
AUTO REFRESH YES
AS
SELECT 
    tu.event_date,  -- Direct column instead of DATE() function
    tu.tool_type,
    COUNT(*) AS usage_count,
    COUNT(DISTINCT tu.thread_id) AS unique_threads,
    COUNT(DISTINCT tu.session_id) AS unique_sessions
FROM tool_usage tu
WHERE tu.event_date IS NOT NULL
GROUP BY tu.event_date, tu.tool_type;

COMMENT ON MATERIALIZED VIEW mv_basic_statistics_opt IS 'Optimized basic stats - requires event_date column in tool_usage';

-- ============================================
-- OPTIMIZATION 4: Separate Distinct Count View
-- ============================================
-- If COUNT(DISTINCT) becomes expensive, use separate aggregation

CREATE MATERIALIZED VIEW mv_distinct_counts
BACKUP NO
AUTO REFRESH YES
AS
SELECT 
    DATE(event_timestamp) AS event_date,
    tool_type,
    thread_id,
    session_id,
    1 AS thread_flag,
    1 AS session_flag
FROM tool_usage
GROUP BY DATE(event_timestamp), tool_type, thread_id, session_id;

-- Then aggregate separately:
CREATE MATERIALIZED VIEW mv_basic_statistics_with_counts
BACKUP NO
AUTO REFRESH YES
AS
SELECT 
    dc.event_date,
    dc.tool_type,
    COUNT(*) AS usage_count,
    SUM(dc.thread_flag) AS unique_threads,
    SUM(dc.session_flag) AS unique_sessions
FROM mv_distinct_counts dc
GROUP BY dc.event_date, dc.tool_type;

COMMENT ON MATERIALIZED VIEW mv_distinct_counts IS 'Intermediate view for distinct count optimization';
COMMENT ON MATERIALIZED VIEW mv_basic_statistics_with_counts IS 'Optimized stats using pre-aggregated distinct counts';

-- ============================================
-- OPTIMIZATION 5: Thread-Based Time Series
-- ============================================
-- For queries that frequently filter by thread_id

CREATE MATERIALIZED VIEW mv_thread_daily_stats
BACKUP NO
AUTO REFRESH YES
AS
SELECT 
    thread_id,
    DATE(event_timestamp) AS event_date,
    tool_type,
    COUNT(*) AS usage_count,
    MIN(event_timestamp) AS first_usage,
    MAX(event_timestamp) AS last_usage
FROM tool_usage
GROUP BY thread_id, DATE(event_timestamp), tool_type;

COMMENT ON MATERIALIZED VIEW mv_thread_daily_stats IS 'Thread-level daily statistics for efficient thread-based queries';

-- ============================================
-- OPTIMIZATION 6: Cost Analytics by Thread
-- ============================================
-- Pre-aggregate cost metrics by thread for user-level queries

CREATE MATERIALIZED VIEW mv_thread_cost_summary
BACKUP NO
AUTO REFRESH YES
AS
SELECT 
    um.thread_id,
    DATE(um.event_timestamp) AS event_date,
    SUM(um.total_tokens) AS total_tokens,
    SUM(um.prompt_tokens) AS total_prompt_tokens,
    SUM(um.completion_tokens) AS total_completion_tokens,
    SUM(um.total_cost) AS total_cost,
    AVG(um.latency_ms) AS avg_latency_ms,
    COUNT(*) AS request_count
FROM usage_metrics um
GROUP BY um.thread_id, DATE(um.event_timestamp);

COMMENT ON MATERIALIZED VIEW mv_thread_cost_summary IS 'Thread-level cost summary for efficient user queries';

