-- ============================================
-- Query Examples for Common Analytics Needs
-- ============================================

-- Goal 1: Basic Statistical Data
-- Get counts by activity type for last 7 days
SELECT * FROM mv_basic_statistics 
WHERE event_date >= CURRENT_DATE - 7
ORDER BY event_date DESC, tool_type;

-- Detailed breakdown by tool type
SELECT 
    tool_type,
    SUM(usage_count) AS total_usage,
    SUM(unique_threads) AS total_unique_threads,
    SUM(unique_sessions) AS total_unique_sessions
FROM mv_basic_statistics
WHERE event_date >= CURRENT_DATE - 30
GROUP BY tool_type
ORDER BY total_usage DESC;

-- Goal 2: Detailed Tool Usage - Domain Analytics
-- Shopping domains usage
SELECT * FROM mv_domain_usage_stats 
WHERE domain_category = 'Shopping'
ORDER BY event_date DESC, action_count DESC;

-- Booking domains usage
SELECT * FROM mv_domain_usage_stats 
WHERE domain_category = 'Booking'
ORDER BY event_date DESC, action_count DESC;

-- All domain categories summary
SELECT 
    domain_category,
    intent_type,
    COUNT(*) AS total_actions,
    SUM(action_count) AS total_action_count,
    COUNT(DISTINCT thread_id) AS unique_threads
FROM mv_domain_usage_stats
WHERE event_date >= CURRENT_DATE - 30
GROUP BY domain_category, intent_type
ORDER BY total_action_count DESC;

-- Browser automation actions
SELECT 
    action_type,
    step_type,
    SUM(action_count) AS total_actions,
    COUNT(DISTINCT unique_threads) AS total_threads
FROM mv_browser_automation_details
WHERE event_date >= CURRENT_DATE - 30
GROUP BY action_type, step_type
ORDER BY total_actions DESC;

-- Web automation actions by category
SELECT 
    domain_category,
    action_type,
    SUM(action_count) AS total_actions
FROM mv_domain_usage_stats
WHERE event_date >= CURRENT_DATE - 7
GROUP BY domain_category, action_type
ORDER BY domain_category, total_actions DESC;

-- Goal 3: Usage Metrics
-- Per-user usage (by thread_id)
SELECT 
    thread_id,
    SUM(usage_count) AS total_usage,
    SUM(total_tokens) AS total_tokens,
    SUM(total_cost) AS total_cost,
    SUM(unique_sessions) AS total_sessions
FROM mv_user_usage_summary
WHERE event_date >= CURRENT_DATE - 30
GROUP BY thread_id
ORDER BY total_usage DESC
LIMIT 100;

-- Total usage across all users
SELECT 
    tool_type,
    SUM(usage_count) AS total_usage_all_users,
    SUM(total_tokens) AS total_tokens_all_users,
    SUM(total_cost) AS total_cost_all_users,
    COUNT(DISTINCT thread_id) AS unique_users
FROM mv_user_usage_summary
WHERE event_date >= CURRENT_DATE - 30
GROUP BY tool_type
ORDER BY total_usage_all_users DESC;

-- Usage trends over time
SELECT 
    event_date,
    tool_type,
    SUM(usage_count) AS daily_usage,
    SUM(total_cost) AS daily_cost
FROM mv_user_usage_summary
WHERE event_date >= CURRENT_DATE - 30
GROUP BY event_date, tool_type
ORDER BY event_date DESC, tool_type;

-- Cost Analytics
-- Cost by model and context size
SELECT 
    event_date,
    model,
    search_context_size,
    request_count,
    total_tokens,
    total_cost,
    avg_latency_ms,
    unique_threads
FROM mv_cost_analytics
WHERE event_date >= CURRENT_DATE - 30
ORDER BY event_date DESC, total_cost DESC;

-- Cost summary
SELECT 
    SUM(total_cost) AS total_cost,
    SUM(total_tokens) AS total_tokens,
    SUM(request_count) AS total_requests,
    AVG(avg_latency_ms) AS avg_latency
FROM mv_cost_analytics
WHERE event_date >= CURRENT_DATE - 30;

-- Web Search Statistics
SELECT 
    event_date,
    search_type,
    search_count,
    unique_threads,
    avg_results_per_search
FROM mv_web_search_statistics
WHERE event_date >= CURRENT_DATE - 30
ORDER BY event_date DESC;

-- Complex Queries
-- User journey: Search -> Web Automation
SELECT 
    ws.thread_id,
    ws.event_timestamp AS search_time,
    ws.search_keywords,
    wa.event_timestamp AS action_time,
    wa.action_type,
    wa.domain_category,
    EXTRACT(EPOCH FROM (wa.event_timestamp - ws.event_timestamp)) AS seconds_between
FROM web_searches ws
INNER JOIN web_automations wa ON ws.thread_id = wa.thread_id
    AND wa.event_timestamp BETWEEN ws.event_timestamp 
    AND ws.event_timestamp + INTERVAL '1 hour'
WHERE ws.event_timestamp >= CURRENT_DATE - 7
ORDER BY ws.thread_id, ws.event_timestamp;

-- Top performing searches (with most automation actions)
SELECT 
    ws.search_keywords,
    COUNT(DISTINCT ws.search_id) AS search_count,
    COUNT(DISTINCT wa.web_action_id) AS action_count,
    COUNT(DISTINCT wa.domain_category) AS domain_categories_touched
FROM web_searches ws
LEFT JOIN web_automations wa ON ws.thread_id = wa.thread_id
    AND wa.event_timestamp BETWEEN ws.event_timestamp 
    AND ws.event_timestamp + INTERVAL '1 hour'
WHERE ws.event_timestamp >= CURRENT_DATE - 30
GROUP BY ws.search_keywords
HAVING COUNT(DISTINCT wa.web_action_id) > 0
ORDER BY action_count DESC
LIMIT 20;

-- Complete session view
SELECT 
    cs.session_id,
    cs.thread_id,
    cs.event_timestamp,
    cs.model,
    cs.status,
    COUNT(DISTINCT tu.tool_type) AS tool_types_used,
    COUNT(tu.tool_usage_id) AS total_tool_calls,
    SUM(um.total_tokens) AS total_tokens,
    SUM(um.total_cost) AS total_cost
FROM chat_sessions cs
LEFT JOIN tool_usage tu ON cs.session_id = tu.session_id
LEFT JOIN usage_metrics um ON cs.session_id = um.session_id
WHERE cs.event_timestamp >= CURRENT_DATE - 7
GROUP BY cs.session_id, cs.thread_id, cs.event_timestamp, cs.model, cs.status
ORDER BY cs.event_timestamp DESC;

-- ============================================
-- LATENCY ANALYSIS QUERIES
-- ============================================

-- Comprehensive Latency Analysis by Model
SELECT 
    event_date,
    model,
    request_count,
    avg_calculated_latency_ms,
    median_latency_ms,
    p95_latency_ms,
    p99_latency_ms,
    avg_cost_per_request,
    avg_tokens_per_request
FROM mv_latency_analytics
WHERE event_date >= CURRENT_DATE - 30
ORDER BY event_date DESC, avg_calculated_latency_ms DESC;

-- Time-of-Day Performance Patterns
SELECT 
    request_hour,
    COUNT(*) AS request_count,
    AVG(avg_calculated_latency_ms) AS avg_latency_ms,
    PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY avg_calculated_latency_ms) AS p95_latency_ms
FROM mv_latency_analytics
WHERE event_date >= CURRENT_DATE - 7
GROUP BY request_hour
ORDER BY request_hour;

-- Latency Impact on Task Completion
SELECT 
    CASE 
        WHEN calculated_latency_ms < 1000 THEN 'Fast (<1s)'
        WHEN calculated_latency_ms < 3000 THEN 'Medium (1-3s)'
        WHEN calculated_latency_ms < 5000 THEN 'Slow (3-5s)'
        ELSE 'Very Slow (>5s)'
    END AS latency_category,
    AVG(CASE WHEN cs.task_completed = TRUE THEN 1.0 ELSE 0.0 END) AS completion_rate,
    COUNT(*) AS request_count,
    AVG(calculated_latency_ms) AS avg_latency_in_category,
    AVG(um.total_cost) AS avg_cost
FROM v_latency_analysis la
LEFT JOIN chat_sessions cs ON la.session_id = cs.session_id
LEFT JOIN usage_metrics um ON la.session_id = um.session_id
WHERE la.event_date >= CURRENT_DATE - 30
GROUP BY latency_category
ORDER BY avg_latency_in_category;

-- Model Performance Comparison
SELECT 
    model,
    COUNT(*) AS request_count,
    AVG(calculated_latency_ms) AS avg_latency_ms,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY calculated_latency_ms) AS median_latency_ms,
    PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY calculated_latency_ms) AS p95_latency_ms,
    AVG(total_cost) AS avg_cost_per_request,
    AVG(total_tokens) AS avg_tokens_per_request
FROM v_latency_analysis
WHERE event_date >= CURRENT_DATE - 30
GROUP BY model
ORDER BY avg_latency_ms;

-- Tool-Specific Latency Analysis
SELECT 
    tool_type,
    COUNT(*) AS usage_count,
    AVG(calculated_latency_ms) AS avg_latency_ms,
    PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY calculated_latency_ms) AS p95_latency_ms,
    AVG(total_cost) AS avg_cost
FROM v_latency_analysis
WHERE event_date >= CURRENT_DATE - 30
    AND tool_type IS NOT NULL
GROUP BY tool_type
ORDER BY avg_latency_ms DESC;

-- Cost-Latency Correlation
SELECT 
    CASE 
        WHEN calculated_latency_ms < 1000 THEN 'Fast'
        WHEN calculated_latency_ms < 3000 THEN 'Medium'
        ELSE 'Slow'
    END AS latency_category,
    AVG(total_cost) AS avg_cost,
    AVG(total_tokens) AS avg_tokens,
    COUNT(*) AS request_count
FROM v_latency_analysis
WHERE event_date >= CURRENT_DATE - 30
GROUP BY latency_category
ORDER BY avg_cost DESC;

-- Latency by Domain Category (Web Automation)
SELECT 
    wa.domain_category,
    AVG(EXTRACT(EPOCH FROM (r.created_timestamp - cs.request_timestamp)) * 1000) AS avg_session_latency_ms,
    COUNT(*) AS action_count,
    AVG(um.total_cost) AS avg_cost
FROM web_automations wa
JOIN chat_sessions cs ON wa.session_id = cs.session_id
JOIN responses r ON cs.response_id = r.response_id
LEFT JOIN usage_metrics um ON cs.session_id = um.session_id
WHERE wa.event_date >= CURRENT_DATE - 30
    AND cs.request_timestamp IS NOT NULL
    AND r.created_timestamp IS NOT NULL
GROUP BY wa.domain_category
ORDER BY avg_session_latency_ms DESC;

-- Daily Latency Trends
SELECT 
    event_date,
    COUNT(*) AS request_count,
    AVG(calculated_latency_ms) AS avg_latency_ms,
    PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY calculated_latency_ms) AS p95_latency_ms,
    PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY calculated_latency_ms) AS p99_latency_ms
FROM v_latency_analysis
WHERE event_date >= CURRENT_DATE - 30
GROUP BY event_date
ORDER BY event_date DESC;

-- Request/Response Timestamp Validation
SELECT 
    session_id,
    reported_latency_ms,
    calculated_latency_ms,
    ABS(reported_latency_ms - calculated_latency_ms) AS latency_difference,
    request_timestamp,
    response_timestamp
FROM v_tool_usage_details
WHERE request_timestamp IS NOT NULL 
    AND response_timestamp IS NOT NULL
    AND ABS(reported_latency_ms - calculated_latency_ms) > 100  -- Flag discrepancies > 100ms
ORDER BY latency_difference DESC
LIMIT 100;

