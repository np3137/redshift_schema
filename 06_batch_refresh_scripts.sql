-- ============================================
-- Batch Refresh Scripts for Materialized Views
-- Non-Real-Time Analytics Configuration
-- ============================================

-- ============================================
-- Script 1: Full Refresh All Views
-- Run daily (recommended: 2 AM)
-- ============================================

-- Refresh log table (create once)
CREATE TABLE IF NOT EXISTS refresh_log (
    log_id BIGINT IDENTITY(1,1),
    refresh_type VARCHAR(50),
    matviewname VARCHAR(255),
    refresh_starttime TIMESTAMP DEFAULT GETDATE(),
    refresh_endtime TIMESTAMP,
    duration_seconds INTEGER,
    status VARCHAR(50),
    error_message TEXT,
    insert_timestamp TIMESTAMP DEFAULT GETDATE(),
    
    DISTKEY(refresh_type),
    SORTKEY(refresh_starttime)
)
ENCODE AUTO;

-- Function to refresh with logging
CREATE OR REPLACE PROCEDURE refresh_materialized_view_with_log(
    mv_name VARCHAR(255)
)
LANGUAGE plpgsql
AS $$
DECLARE
    start_time TIMESTAMP;
    end_time TIMESTAMP;
    duration INTEGER;
BEGIN
    start_time := GETDATE();
    
    BEGIN
        EXECUTE 'REFRESH MATERIALIZED VIEW ' || mv_name;
        end_time := GETDATE();
        duration := EXTRACT(EPOCH FROM (end_time - start_time))::INTEGER;
        
        INSERT INTO refresh_log (
            refresh_type,
            matviewname,
            refresh_starttime,
            refresh_endtime,
            duration_seconds,
            status
        ) VALUES (
            'full',
            mv_name,
            start_time,
            end_time,
            duration,
            'success'
        );
        
        RAISE NOTICE 'Refreshed % in % seconds', mv_name, duration;
        
    EXCEPTION WHEN OTHERS THEN
        INSERT INTO refresh_log (
            refresh_type,
            matviewname,
            refresh_starttime,
            refresh_endtime,
            duration_seconds,
            status,
            error_message
        ) VALUES (
            'full',
            mv_name,
            start_time,
            GETDATE(),
            EXTRACT(EPOCH FROM (GETDATE() - start_time))::INTEGER,
            'failed',
            SQLERRM
        );
        
        RAISE;
    END;
END;
$$;

-- ============================================
-- Script 2: Refresh All Views (Daily Batch)
-- ============================================

-- Full refresh procedure
CREATE OR REPLACE PROCEDURE refresh_all_materialized_views()
LANGUAGE plpgsql
AS $$
BEGIN
    -- Refresh all materialized views
    CALL refresh_materialized_view_with_log('mv_basic_statistics');
    CALL refresh_materialized_view_with_log('mv_user_usage_summary');
    CALL refresh_materialized_view_with_log('mv_domain_usage_stats');
    CALL refresh_materialized_view_with_log('mv_browser_automation_details');
    CALL refresh_materialized_view_with_log('mv_cost_analytics');
    CALL refresh_materialized_view_with_log('mv_web_search_statistics');
    CALL refresh_materialized_view_with_log('mv_browser_history_analytics');
    CALL refresh_materialized_view_with_log('mv_task_completion_stats');
    
    RAISE NOTICE 'All materialized views refreshed successfully';
END;
$$;

-- Execute refresh
-- CALL refresh_all_materialized_views();

-- ============================================
-- Script 3: Incremental Refresh (Recent Data Only)
-- ============================================

-- Refresh only views with recent data
CREATE OR REPLACE PROCEDURE refresh_recent_materialized_views(
    days_back INTEGER DEFAULT 7
)
LANGUAGE plpgsql
AS $$
DECLARE
    cutoff_date DATE;
BEGIN
    cutoff_date := CURRENT_DATE - days_back;
    
    -- Only refresh views that have recent data
    -- Note: Redshift doesn't support incremental refresh directly
    -- This is a conceptual approach - you may need to recreate views
    
    RAISE NOTICE 'Refreshing views with data from % onwards', cutoff_date;
    
    -- Refresh all views (full refresh required)
    CALL refresh_all_materialized_views();
    
    RAISE NOTICE 'Incremental refresh completed';
END;
$$;

-- ============================================
-- Script 4: Check Refresh Status
-- ============================================

-- View to check refresh status
CREATE OR REPLACE VIEW v_materialized_view_refresh_status AS
SELECT 
    mv.schemaname,
    mv.matviewname,
    mv.last_refresh_starttime,
    mv.last_refresh_completiontime,
    EXTRACT(EPOCH FROM (
        mv.last_refresh_completiontime - mv.last_refresh_starttime
    )) AS refresh_duration_seconds,
    mv.refresh_status,
    CASE 
        WHEN mv.last_refresh_starttime IS NULL THEN 'Never Refreshed'
        WHEN mv.last_refresh_completiontime IS NULL THEN 'In Progress'
        WHEN EXTRACT(EPOCH FROM (CURRENT_TIMESTAMP - mv.last_refresh_completiontime)) < 3600 THEN 'Recent (< 1 hour)'
        WHEN EXTRACT(EPOCH FROM (CURRENT_TIMESTAMP - mv.last_refresh_completiontime)) < 86400 THEN 'Today'
        WHEN EXTRACT(EPOCH FROM (CURRENT_TIMESTAMP - mv.last_refresh_completiontime)) < 172800 THEN 'Yesterday'
        ELSE 'Stale (> 2 days)'
    END AS freshness_status
FROM pg_matviews mv
WHERE mv.matviewname LIKE 'mv_%'
ORDER BY mv.last_refresh_starttime DESC;

COMMENT ON VIEW v_materialized_view_refresh_status IS 'Materialized view refresh status and freshness indicator';

-- ============================================
-- Script 5: Refresh Performance Report
-- ============================================

-- View for refresh performance analysis
CREATE OR REPLACE VIEW v_refresh_performance AS
SELECT 
    rl.matviewname,
    COUNT(*) AS refresh_count,
    AVG(rl.duration_seconds) AS avg_duration_seconds,
    MIN(rl.duration_seconds) AS min_duration_seconds,
    MAX(rl.duration_seconds) AS max_duration_seconds,
    SUM(CASE WHEN rl.status = 'success' THEN 1 ELSE 0 END) AS success_count,
    SUM(CASE WHEN rl.status = 'failed' THEN 1 ELSE 0 END) AS failed_count,
    MAX(rl.refresh_endtime) AS last_refresh_time
FROM refresh_log rl
WHERE rl.refresh_starttime >= CURRENT_DATE - 30
GROUP BY rl.matviewname
ORDER BY avg_duration_seconds DESC;

COMMENT ON VIEW v_refresh_performance IS 'Materialized view refresh performance metrics (last 30 days)';

-- ============================================
-- Script 6: Quick Refresh Check Query
-- ============================================

-- Query to check if refresh is needed
SELECT 
    matviewname,
    CASE 
        WHEN last_refresh_completiontime IS NULL THEN 'NEEDS_REFRESH'
        WHEN EXTRACT(EPOCH FROM (CURRENT_TIMESTAMP - last_refresh_completiontime)) > 86400 THEN 'STALE'
        ELSE 'CURRENT'
    END AS refresh_status,
    last_refresh_completiontime,
    EXTRACT(EPOCH FROM (CURRENT_TIMESTAMP - last_refresh_completiontime)) / 3600 AS hours_since_refresh
FROM pg_matviews
WHERE matviewname LIKE 'mv_%'
ORDER BY last_refresh_completiontime NULLS FIRST;

-- ============================================
-- Usage Examples
-- ============================================

-- Example 1: Daily refresh (run via cron/scheduler)
-- CALL refresh_all_materialized_views();

-- Example 2: Check refresh status
-- SELECT * FROM v_materialized_view_refresh_status;

-- Example 3: Check refresh performance
-- SELECT * FROM v_refresh_performance;

-- Example 4: Manual refresh of specific view
-- CALL refresh_materialized_view_with_log('mv_basic_statistics');

-- Example 5: View refresh log
-- SELECT * FROM refresh_log 
-- WHERE refresh_starttime >= CURRENT_DATE - 7
-- ORDER BY refresh_starttime DESC;

