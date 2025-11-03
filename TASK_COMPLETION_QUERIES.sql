-- ============================================
-- Task Completion Query Examples
-- ============================================

-- Query 1: Overall Task Completion Rate
-- Get the overall success rate of tasks
SELECT 
    COUNT(*) AS total_tasks,
    SUM(CASE WHEN task_completed = TRUE THEN 1 ELSE 0 END) AS completed_tasks,
    SUM(CASE WHEN task_completed = FALSE THEN 1 ELSE 0 END) AS failed_tasks,
    SUM(CASE WHEN task_completed IS NULL THEN 1 ELSE 0 END) AS in_progress_tasks,
    ROUND(
        100.0 * SUM(CASE WHEN task_completed = TRUE THEN 1 ELSE 0 END) / 
        NULLIF(COUNT(*), 0),
        2
    ) AS completion_rate_percent,
    ROUND(
        100.0 * SUM(CASE WHEN task_completed = FALSE THEN 1 ELSE 0 END) / 
        NULLIF(COUNT(*), 0),
        2
    ) AS failure_rate_percent
FROM chat_sessions
WHERE task_completed IS NOT NULL;

-- Query 2: Task Completion by Status
-- Breakdown of tasks by completion status
SELECT 
    task_completion_status,
    COUNT(*) AS task_count,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS percentage
FROM chat_sessions
WHERE task_completion_status IS NOT NULL
GROUP BY task_completion_status
ORDER BY task_count DESC;

-- Query 3: Task Completion Rate by Domain Category
-- Which domains have highest/lowest completion rates
SELECT 
    wa.domain_category,
    COUNT(DISTINCT cs.session_id) AS total_sessions,
    SUM(CASE WHEN cs.task_completed = TRUE THEN 1 ELSE 0 END) AS completed_sessions,
    SUM(CASE WHEN cs.task_completed = FALSE THEN 1 ELSE 0 END) AS failed_sessions,
    ROUND(
        100.0 * SUM(CASE WHEN cs.task_completed = TRUE THEN 1 ELSE 0 END) / 
        NULLIF(COUNT(DISTINCT cs.session_id), 0),
        2
    ) AS completion_rate_percent
FROM chat_sessions cs
INNER JOIN web_automations wa ON cs.session_id = wa.session_id
WHERE cs.task_completed IS NOT NULL
GROUP BY wa.domain_category
ORDER BY completion_rate_percent DESC;

-- Query 4: Task Completion Trends Over Time
-- Daily task completion rates
SELECT 
    DATE(cs.event_timestamp) AS completion_date,
    COUNT(*) AS total_tasks,
    SUM(CASE WHEN cs.task_completed = TRUE THEN 1 ELSE 0 END) AS completed_tasks,
    SUM(CASE WHEN cs.task_completed = FALSE THEN 1 ELSE 0 END) AS failed_tasks,
    ROUND(
        100.0 * SUM(CASE WHEN cs.task_completed = TRUE THEN 1 ELSE 0 END) / 
        NULLIF(COUNT(*), 0),
        2
    ) AS completion_rate_percent
FROM chat_sessions cs
WHERE cs.task_completed IS NOT NULL
GROUP BY DATE(cs.event_timestamp)
ORDER BY completion_date DESC;

-- Query 5: Action-Level Task Completion Analysis
-- Completion rate by action type and domain
SELECT 
    wa.action_type,
    wa.domain_category,
    COUNT(*) AS total_actions,
    SUM(CASE WHEN wa.task_completed = TRUE THEN 1 ELSE 0 END) AS completed_actions,
    SUM(CASE WHEN wa.task_status = 'Succeeded' THEN 1 ELSE 0 END) AS succeeded_actions,
    SUM(CASE WHEN wa.task_status = 'Failed' THEN 1 ELSE 0 END) AS failed_actions,
    ROUND(
        100.0 * SUM(CASE WHEN wa.task_completed = TRUE THEN 1 ELSE 0 END) / 
        NULLIF(COUNT(*), 0),
        2
    ) AS action_completion_rate
FROM web_automations wa
WHERE wa.task_completed IS NOT NULL OR wa.task_status IS NOT NULL
GROUP BY wa.action_type, wa.domain_category
ORDER BY action_completion_rate DESC;

-- Query 6: Task Completion with Failure Reasons
-- Analyze common failure reasons
SELECT 
    task_completion_reason,
    COUNT(*) AS failure_count,
    COUNT(DISTINCT session_id) AS unique_sessions,
    COUNT(DISTINCT thread_id) AS unique_threads,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS percentage_of_failures
FROM chat_sessions
WHERE task_completed = FALSE
    AND task_completion_reason IS NOT NULL
GROUP BY task_completion_reason
ORDER BY failure_count DESC;

-- Query 7: Task Completion by Model
-- Which AI models have better completion rates
SELECT 
    cs.model,
    COUNT(*) AS total_tasks,
    SUM(CASE WHEN cs.task_completed = TRUE THEN 1 ELSE 0 END) AS completed_tasks,
    SUM(CASE WHEN cs.task_completed = FALSE THEN 1 ELSE 0 END) AS failed_tasks,
    ROUND(
        100.0 * SUM(CASE WHEN cs.task_completed = TRUE THEN 1 ELSE 0 END) / 
        NULLIF(COUNT(*), 0),
        2
    ) AS completion_rate_percent,
    AVG(um.total_cost) AS avg_cost_per_task
FROM chat_sessions cs
LEFT JOIN usage_metrics um ON cs.session_id = um.session_id
WHERE cs.task_completed IS NOT NULL
GROUP BY cs.model
ORDER BY completion_rate_percent DESC;

-- Query 8: Partial vs Full Task Completion
-- Analyze partial completions
SELECT 
    task_completion_status,
    COUNT(*) AS count,
    COUNT(DISTINCT session_id) AS unique_sessions,
    AVG(
        CASE WHEN task_completed = TRUE THEN 1.0 ELSE 0.0 END
    ) AS avg_completion_score
FROM chat_sessions
WHERE task_completion_status IN ('partial', 'completed', 'failed')
GROUP BY task_completion_status
ORDER BY count DESC;

-- Query 9: Task Completion Rate by Thread
-- Per-user/thread completion rates
SELECT 
    cs.thread_id,
    COUNT(*) AS total_tasks,
    SUM(CASE WHEN cs.task_completed = TRUE THEN 1 ELSE 0 END) AS completed_tasks,
    ROUND(
        100.0 * SUM(CASE WHEN cs.task_completed = TRUE THEN 1 ELSE 0 END) / 
        NULLIF(COUNT(*), 0),
        2
    ) AS thread_completion_rate
FROM chat_sessions cs
WHERE cs.task_completed IS NOT NULL
GROUP BY cs.thread_id
HAVING COUNT(*) >= 3  -- Only threads with 3+ tasks
ORDER BY thread_completion_rate DESC
LIMIT 100;

-- Query 10: Using Materialized View for Fast Analytics
-- Fast query using pre-aggregated materialized view
SELECT 
    completion_date,
    task_completion_status,
    domain_category,
    task_count,
    completed_count,
    failed_count,
    completion_rate_percent
FROM mv_task_completion_stats
WHERE completion_date >= CURRENT_DATE - 30
ORDER BY completion_date DESC, completion_rate_percent DESC;

-- Query 11: Task Completion Correlation with Cost
-- Do successful tasks cost more/less?
SELECT 
    CASE 
        WHEN cs.task_completed = TRUE THEN 'Completed'
        WHEN cs.task_completed = FALSE THEN 'Failed'
        ELSE 'In Progress'
    END AS task_status,
    COUNT(*) AS task_count,
    AVG(um.total_cost) AS avg_cost,
    AVG(um.total_tokens) AS avg_tokens,
    AVG(um.latency_ms) AS avg_latency_ms
FROM chat_sessions cs
LEFT JOIN usage_metrics um ON cs.session_id = um.session_id
WHERE cs.task_completed IS NOT NULL
GROUP BY cs.task_completed
ORDER BY avg_cost DESC;

-- Query 12: Failed Tasks Analysis with Domain Details
-- Detailed failure analysis
SELECT 
    cs.task_completion_status,
    cs.task_completion_reason,
    wa.domain_category,
    wa.action_type,
    COUNT(*) AS failure_count
FROM chat_sessions cs
INNER JOIN web_automations wa ON cs.session_id = wa.session_id
WHERE cs.task_completed = FALSE
GROUP BY cs.task_completion_status, cs.task_completion_reason, wa.domain_category, wa.action_type
ORDER BY failure_count DESC;

-- Query 13: Task Completion Rate by Action Type
-- Which actions are most/least successful
SELECT 
    wa.action_type,
    COUNT(*) AS total_actions,
    SUM(CASE WHEN wa.task_completed = TRUE THEN 1 ELSE 0 END) AS successful_actions,
    SUM(CASE WHEN wa.task_completed = FALSE THEN 1 ELSE 0 END) AS failed_actions,
    ROUND(
        100.0 * SUM(CASE WHEN wa.task_completed = TRUE THEN 1 ELSE 0 END) / 
        NULLIF(COUNT(*), 0),
        2
    ) AS success_rate
FROM web_automations wa
WHERE wa.task_completed IS NOT NULL
GROUP BY wa.action_type
ORDER BY success_rate DESC;

-- Query 14: Task Completion Time Analysis
-- How long do tasks take to complete
SELECT 
    CASE 
        WHEN cs.task_completed = TRUE THEN 'Completed'
        WHEN cs.task_completed = FALSE THEN 'Failed'
    END AS task_status,
    COUNT(*) AS task_count,
    AVG(EXTRACT(EPOCH FROM (cs.created_timestamp - cs.event_timestamp))) AS avg_duration_seconds,
    MIN(EXTRACT(EPOCH FROM (cs.created_timestamp - cs.event_timestamp))) AS min_duration_seconds,
    MAX(EXTRACT(EPOCH FROM (cs.created_timestamp - cs.event_timestamp))) AS max_duration_seconds
FROM chat_sessions cs
WHERE cs.task_completed IS NOT NULL
    AND cs.created_timestamp IS NOT NULL
    AND cs.event_timestamp IS NOT NULL
GROUP BY cs.task_completed;

-- Query 15: Weekly Task Completion Summary
-- Weekly trends
SELECT 
    DATE_TRUNC('week', cs.event_timestamp) AS week_start,
    COUNT(*) AS total_tasks,
    SUM(CASE WHEN cs.task_completed = TRUE THEN 1 ELSE 0 END) AS completed_tasks,
    ROUND(
        100.0 * SUM(CASE WHEN cs.task_completed = TRUE THEN 1 ELSE 0 END) / 
        NULLIF(COUNT(*), 0),
        2
    ) AS weekly_completion_rate
FROM chat_sessions cs
WHERE cs.task_completed IS NOT NULL
GROUP BY DATE_TRUNC('week', cs.event_timestamp)
ORDER BY week_start DESC;

