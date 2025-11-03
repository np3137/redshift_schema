-- ============================================
-- Materialized Views for Query Optimization
-- BATCH/Non-Real-Time Analytics Configuration
-- ============================================
-- NOTE: All views use AUTO REFRESH NO for batch processing
-- Refresh manually during scheduled ETL windows (e.g., hourly/daily)

-- 1. mv_basic_statistics: Goal 1 & 3 - Basic Stats & Usage Metrics
-- Tracks: Search, Browser Automation, Web Automation counts
-- OPTIMIZED: Uses event_date column instead of DATE() function for better sort key usage
-- BATCH: Manual refresh for non-real-time analytics
CREATE MATERIALIZED VIEW mv_basic_statistics
BACKUP NO
AUTO REFRESH NO  -- Changed to NO for batch processing
AS
SELECT 
    tu.event_date,
    tu.tool_type,
    COUNT(*) AS usage_count,
    COUNT(DISTINCT tu.thread_id) AS unique_threads,
    COUNT(DISTINCT tu.session_id) AS unique_sessions
FROM tool_usage tu
WHERE tu.event_date IS NOT NULL
GROUP BY tu.event_date, tu.tool_type;

COMMENT ON MATERIALIZED VIEW mv_basic_statistics IS 'Basic statistics: Counts by activity type (Goal 1 & 3). OPTIMIZED: Uses event_date column for better performance';

-- 2. mv_user_usage_summary: Goal 3 - Per-User Usage Metrics
-- OPTIMIZED: Uses event_date column and efficient JOIN on DISTKEY (session_id)
-- LATENCY: Added latency metrics for user experience analysis
-- BATCH: Manual refresh for non-real-time analytics
CREATE MATERIALIZED VIEW mv_user_usage_summary
BACKUP NO
AUTO REFRESH NO  -- Changed to NO for batch processing
AS
SELECT 
    tu.thread_id,
    tu.event_date,
    tu.tool_type,
    COUNT(*) AS usage_count,
    COUNT(DISTINCT tu.session_id) AS unique_sessions,
    SUM(COALESCE(um.total_tokens, 0)) AS total_tokens,
    SUM(COALESCE(um.total_cost, 0)) AS total_cost,
    SUM(COALESCE(um.prompt_tokens, 0)) AS total_prompt_tokens,
    SUM(COALESCE(um.completion_tokens, 0)) AS total_completion_tokens,
    AVG(CASE 
        WHEN um.request_timestamp IS NOT NULL AND um.response_timestamp IS NOT NULL 
        THEN EXTRACT(EPOCH FROM (um.response_timestamp - um.request_timestamp)) * 1000 
        ELSE um.latency_ms 
    END) AS avg_latency_ms
FROM tool_usage tu
LEFT JOIN usage_metrics um ON tu.session_id = um.session_id  -- JOIN on DISTKEY column (session_id) for efficiency
    AND tu.thread_id = um.thread_id  -- Additional filter for matching thread
    AND tu.event_date = um.event_date  -- Additional filter for better performance
WHERE tu.event_date IS NOT NULL
GROUP BY tu.thread_id, tu.event_date, tu.tool_type;

COMMENT ON MATERIALIZED VIEW mv_user_usage_summary IS 'Per-user usage metrics aggregated by thread_id (Goal 3). LATENCY: Includes average latency for user experience analysis. OPTIMIZED: Uses event_date and JOIN on DISTKEY column (session_id)';

-- 3. mv_domain_usage_stats: Goal 2 - Domain Analytics
-- Tracks: Shopping, Booking, Entertainment, Work, Education, Finance domains
-- OPTIMIZED: Assumes domain_category is populated in ETL (no COALESCE needed)
-- BATCH: Manual refresh for non-real-time analytics
CREATE MATERIALIZED VIEW mv_domain_usage_stats
BACKUP NO
AUTO REFRESH NO  -- Changed to NO for batch processing
AS
SELECT 
    wa.domain_category,  -- No COALESCE - populated in ETL
    COALESCE(dc.intent_type, 'Unknown') AS intent_type,
    wa.domain_name,
    wa.event_date,
    wa.action_type,
    COUNT(*) AS action_count,
    COUNT(DISTINCT wa.thread_id) AS unique_threads,
    COUNT(DISTINCT wa.session_id) AS unique_sessions
FROM web_automations wa
LEFT JOIN domain_classifications dc ON wa.domain_name = dc.domain_name 
    AND dc.is_active = TRUE
WHERE wa.domain_category IS NOT NULL 
    AND wa.domain_name IS NOT NULL
    AND wa.event_date IS NOT NULL
GROUP BY 
    wa.domain_category,
    COALESCE(dc.intent_type, 'Unknown'),
    wa.domain_name,
    wa.event_date,
    wa.action_type;

COMMENT ON MATERIALIZED VIEW mv_domain_usage_stats IS 'Domain-based analytics for web automation actions (Goal 2). OPTIMIZED: Uses event_date and assumes domain_category populated in ETL (no COALESCE in GROUP BY)';

-- 4. mv_browser_automation_details: Goal 2 - Browser Automation Tracking
-- REFACTORED: Uses event_date column (no DATE function needed), optimized for performance
-- BATCH: Manual refresh for non-real-time analytics
CREATE MATERIALIZED VIEW mv_browser_automation_details
BACKUP NO
AUTO REFRESH NO  -- Changed to NO for batch processing
AS
SELECT 
    ba.event_date,  -- REFACTORED: Uses event_date column instead of DATE function
    ba.action_type,
    ba.step_type,
    COUNT(*) AS action_count,
    COUNT(DISTINCT ba.thread_id) AS unique_threads,
    COUNT(DISTINCT ba.session_id) AS unique_sessions,
    COUNT(DISTINCT ba.user_id) AS unique_users
FROM browser_automations ba
WHERE ba.event_date IS NOT NULL
    AND (ba.action_type IS NOT NULL OR ba.step_type IS NOT NULL)
GROUP BY ba.event_date, ba.action_type, ba.step_type;

COMMENT ON MATERIALIZED VIEW mv_browser_automation_details IS 'Browser automation action details. REFACTORED: Uses event_date column for better performance';

-- 5. mv_cost_analytics: Token Usage, Cost, Latency Analytics
-- OPTIMIZED: Uses event_date column instead of DATE() function
-- LATENCY: Enhanced with calculated latency from timestamps for accuracy
-- BATCH: Manual refresh for non-real-time analytics
CREATE MATERIALIZED VIEW mv_cost_analytics
BACKUP NO
AUTO REFRESH NO  -- Changed to NO for batch processing
AS
SELECT 
    um.event_date,
    um.model,
    um.search_context_size,
    COUNT(*) AS request_count,
    SUM(um.total_tokens) AS total_tokens,
    SUM(um.prompt_tokens) AS total_prompt_tokens,
    SUM(um.completion_tokens) AS total_completion_tokens,
    SUM(um.total_cost) AS total_cost,
    SUM(um.input_tokens_cost) AS total_input_cost,
    SUM(um.output_tokens_cost) AS total_output_cost,
    SUM(um.request_cost) AS total_request_cost,
    AVG(um.latency_ms) AS avg_reported_latency_ms,
    AVG(CASE 
        WHEN um.request_timestamp IS NOT NULL AND um.response_timestamp IS NOT NULL 
        THEN EXTRACT(EPOCH FROM (um.response_timestamp - um.request_timestamp)) * 1000 
        ELSE NULL 
    END) AS avg_calculated_latency_ms,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY 
        CASE 
            WHEN um.request_timestamp IS NOT NULL AND um.response_timestamp IS NOT NULL 
            THEN EXTRACT(EPOCH FROM (um.response_timestamp - um.request_timestamp)) * 1000 
            ELSE um.latency_ms 
        END
    ) AS median_latency_ms,
    PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY 
        CASE 
            WHEN um.request_timestamp IS NOT NULL AND um.response_timestamp IS NOT NULL 
            THEN EXTRACT(EPOCH FROM (um.response_timestamp - um.request_timestamp)) * 1000 
            ELSE um.latency_ms 
        END
    ) AS p95_latency_ms,
    COUNT(DISTINCT um.thread_id) AS unique_threads,
    COUNT(DISTINCT um.session_id) AS unique_sessions
FROM usage_metrics um
WHERE um.event_date IS NOT NULL
GROUP BY um.event_date, um.model, um.search_context_size;

COMMENT ON MATERIALIZED VIEW mv_cost_analytics IS 'Cost, token usage, and latency analytics. LATENCY: Enhanced with calculated latency from request/response timestamps for accurate analysis. OPTIMIZED: Uses event_date column for better performance';

-- 6. mv_web_search_statistics: Web Search Analytics
-- AGGREGATIONS: All counts and aggregations calculated here (not in base table)
-- BATCH: Manual refresh for non-real-time analytics
CREATE MATERIALIZED VIEW mv_web_search_statistics
BACKUP NO
AUTO REFRESH NO  -- Changed to NO for batch processing
AS
SELECT 
    ws.event_date,
    ws.search_type,
    COUNT(*) AS search_count,  -- Aggregation: Count of searches
    COUNT(DISTINCT ws.thread_id) AS unique_threads,  -- Aggregation: Distinct threads
    COUNT(DISTINCT ws.session_id) AS unique_sessions,  -- Aggregation: Distinct sessions
    AVG(ws.num_results) AS avg_results_per_search,  -- Aggregation: Average results per search
    SUM(ws.num_results) AS total_results_returned  -- Aggregation: Total results (sum of num_results)
FROM web_searches ws
WHERE ws.event_date IS NOT NULL
GROUP BY ws.event_date, ws.search_type;

COMMENT ON MATERIALIZED VIEW mv_web_search_statistics IS 'Web search operation statistics. AGGREGATIONS: All counts and aggregations calculated in materialized view (not in base table)';

-- 7. mv_task_completion_stats: Task Completion Analytics
-- REFACTORED: Uses event_date column instead of DATE function, optimized JOIN
-- BATCH: Manual refresh for non-real-time analytics
CREATE MATERIALIZED VIEW mv_task_completion_stats
BACKUP NO
AUTO REFRESH NO  -- Changed to NO for batch processing
AS
SELECT 
    cs.event_date,  -- REFACTORED: Uses event_date column instead of DATE function
    cs.task_completion_status,
    r.status AS response_status,  -- From responses table (normalized)
    COALESCE(wa.domain_category, 'Unknown') AS domain_category,
    COUNT(*) AS task_count,
    SUM(CASE WHEN cs.task_completed = TRUE THEN 1 ELSE 0 END) AS completed_count,
    SUM(CASE WHEN cs.task_completed = FALSE THEN 1 ELSE 0 END) AS failed_count,
    SUM(CASE WHEN cs.task_completed IS NULL THEN 1 ELSE 0 END) AS in_progress_count,
    ROUND(
        100.0 * SUM(CASE WHEN cs.task_completed = TRUE THEN 1 ELSE 0 END) / 
        NULLIF(SUM(CASE WHEN cs.task_completed IS NOT NULL THEN 1 ELSE 0 END), 0),
        2
    ) AS completion_rate_percent
FROM chat_sessions cs
LEFT JOIN responses r ON cs.response_id = r.response_id  -- Join to get response status
LEFT JOIN web_automations wa ON cs.session_id = wa.session_id
    AND cs.event_date = wa.event_date  -- REFACTORED: Added date filter for better JOIN performance
WHERE cs.event_date IS NOT NULL
    AND (cs.task_completed IS NOT NULL OR cs.task_completion_status IS NOT NULL)
GROUP BY cs.event_date, cs.task_completion_status, r.status, COALESCE(wa.domain_category, 'Unknown');

COMMENT ON MATERIALIZED VIEW mv_task_completion_stats IS 'Task completion statistics. REFACTORED: Uses event_date column, optimized JOIN with date filter';

-- 8. mv_latency_analytics: Comprehensive Latency Analysis
-- LATENCY: Detailed latency analysis with time-of-day patterns and model comparison
-- BATCH: Manual refresh for non-real-time analytics
CREATE MATERIALIZED VIEW mv_latency_analytics
BACKUP NO
AUTO REFRESH NO
AS
SELECT 
    um.event_date,
    EXTRACT(HOUR FROM um.request_timestamp) AS request_hour,  -- Time-of-day analysis
    um.model,
    tu.tool_type,
    COUNT(*) AS request_count,
    -- Calculated latency from timestamps (more accurate)
    AVG(CASE 
        WHEN um.request_timestamp IS NOT NULL AND um.response_timestamp IS NOT NULL 
        THEN EXTRACT(EPOCH FROM (um.response_timestamp - um.request_timestamp)) * 1000 
        ELSE NULL 
    END) AS avg_calculated_latency_ms,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY 
        CASE 
            WHEN um.request_timestamp IS NOT NULL AND um.response_timestamp IS NOT NULL 
            THEN EXTRACT(EPOCH FROM (um.response_timestamp - um.request_timestamp)) * 1000 
            ELSE NULL 
        END
    ) AS median_latency_ms,
    PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY 
        CASE 
            WHEN um.request_timestamp IS NOT NULL AND um.response_timestamp IS NOT NULL 
            THEN EXTRACT(EPOCH FROM (um.response_timestamp - um.request_timestamp)) * 1000 
            ELSE NULL 
        END
    ) AS p95_latency_ms,
    PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY 
        CASE 
            WHEN um.request_timestamp IS NOT NULL AND um.response_timestamp IS NOT NULL 
            THEN EXTRACT(EPOCH FROM (um.response_timestamp - um.request_timestamp)) * 1000 
            ELSE NULL 
        END
    ) AS p99_latency_ms,
    -- Correlation with cost and tokens
    AVG(um.total_cost) AS avg_cost_per_request,
    AVG(um.total_tokens) AS avg_tokens_per_request,
    -- Session-level latency (from chat_sessions)
    AVG(EXTRACT(EPOCH FROM (r.created_timestamp - cs.request_timestamp)) * 1000) AS avg_session_latency_ms,
    COUNT(DISTINCT um.session_id) AS unique_sessions,
    COUNT(DISTINCT um.thread_id) AS unique_threads
FROM usage_metrics um
LEFT JOIN tool_usage tu ON um.session_id = tu.session_id 
    AND um.thread_id = tu.thread_id
    AND um.event_date = tu.event_date
LEFT JOIN chat_sessions cs ON um.session_id = cs.session_id
LEFT JOIN responses r ON cs.response_id = r.response_id
WHERE um.event_date IS NOT NULL
    AND um.request_timestamp IS NOT NULL
    AND um.response_timestamp IS NOT NULL
GROUP BY um.event_date, EXTRACT(HOUR FROM um.request_timestamp), um.model, tu.tool_type;

COMMENT ON MATERIALIZED VIEW mv_latency_analytics IS 'Comprehensive latency analysis with time-of-day patterns, model comparison, and correlation with costs. LATENCY: Uses calculated latency from request/response timestamps for accurate analysis';

