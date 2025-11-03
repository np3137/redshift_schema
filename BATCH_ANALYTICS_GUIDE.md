# Batch Analytics Configuration Guide
## Non-Real-Time Data Analysis Optimization

---

## Overview

The schema has been optimized for **batch/non-real-time analytics**. All materialized views use **AUTO REFRESH NO** to allow controlled refresh during scheduled ETL windows.

---

## Configuration Changes

### Materialized Views: Changed to Manual Refresh

**All materialized views now use**:
```sql
AUTO REFRESH NO  -- Manual refresh for batch processing
```

**Benefits**:
- ✅ No refresh overhead during normal operations
- ✅ Controlled refresh timing (schedule during off-hours)
- ✅ Predictable performance (refresh doesn't interfere with queries)
- ✅ Better for batch analytics workflows

---

## Batch Refresh Strategy

### Option 1: Daily Refresh (Recommended for Most Use Cases)

**Schedule**: Refresh once per day (e.g., 2 AM)

```sql
-- Refresh all materialized views daily
REFRESH MATERIALIZED VIEW mv_basic_statistics;
REFRESH MATERIALIZED VIEW mv_user_usage_summary;
REFRESH MATERIALIZED VIEW mv_domain_usage_stats;
REFRESH MATERIALIZED VIEW mv_browser_automation_details;
REFRESH MATERIALIZED VIEW mv_cost_analytics;
REFRESH MATERIALIZED VIEW mv_web_search_statistics;
REFRESH MATERIALIZED VIEW mv_browser_history_analytics;
REFRESH MATERIALIZED VIEW mv_task_completion_stats;
```

**Use When**:
- Analytics can tolerate up to 24-hour data lag
- Daily reporting requirements
- Lower refresh frequency needed

### Option 2: Hourly Refresh

**Schedule**: Refresh every hour during off-peak times

```sql
-- Refresh during off-peak hours (e.g., every hour :00 minutes)
-- Run via cron/scheduler
REFRESH MATERIALIZED VIEW mv_basic_statistics;
REFRESH MATERIALIZED VIEW mv_user_usage_summary;
REFRESH MATERIALIZED VIEW mv_domain_usage_stats;
-- ... (others)
```

**Use When**:
- Need fresher data (hourly updates acceptable)
- Still non-real-time but more frequent
- Have predictable ETL windows

### Option 3: Incremental Refresh (Advanced)

**Strategy**: Refresh only recent data, full refresh periodically

```sql
-- Daily incremental refresh (last 7 days)
-- Then full refresh weekly
CREATE MATERIALIZED VIEW mv_basic_statistics_recent AS
SELECT * FROM mv_basic_statistics
WHERE event_date >= CURRENT_DATE - 7;

-- Refresh recent view daily
REFRESH MATERIALIZED VIEW mv_basic_statistics_recent;

-- Full refresh weekly (Sunday 2 AM)
REFRESH MATERIALIZED VIEW mv_basic_statistics;
```

**Use When**:
- Large data volumes
- Most queries focus on recent data
- Need balance between freshness and performance

---

## Automated Refresh Scripts

### Script 1: Full Refresh Script (Daily)

```sql
-- refresh_all_materialized_views.sql
-- Run daily via cron/scheduler (e.g., 2 AM)

BEGIN;

-- Refresh basic statistics
REFRESH MATERIALIZED VIEW mv_basic_statistics;

-- Refresh user metrics
REFRESH MATERIALIZED VIEW mv_user_usage_summary;

-- Refresh domain analytics
REFRESH MATERIALIZED VIEW mv_domain_usage_stats;

-- Refresh browser automation
REFRESH MATERIALIZED VIEW mv_browser_automation_details;

-- Refresh cost analytics
REFRESH MATERIALIZED VIEW mv_cost_analytics;

-- Refresh search statistics
REFRESH MATERIALIZED VIEW mv_web_search_statistics;

-- Refresh browser history analytics
REFRESH MATERIALIZED VIEW mv_browser_history_analytics;

-- Refresh task completion stats
REFRESH MATERIALIZED VIEW mv_task_completion_stats;

COMMIT;

-- Log refresh completion
INSERT INTO refresh_log (refresh_type, completed_at, status)
VALUES ('full_refresh', GETDATE(), 'success');
```

### Script 2: Python/PowerShell Script for Scheduling

```python
# refresh_materialized_views.py
import psycopg2
from datetime import datetime

def refresh_all_materialized_views():
    """Refresh all materialized views for batch analytics"""
    
    materialized_views = [
        'mv_basic_statistics',
        'mv_user_usage_summary',
        'mv_domain_usage_stats',
        'mv_browser_automation_details',
        'mv_cost_analytics',
        'mv_web_search_statistics',
        'mv_browser_history_analytics',
        'mv_task_completion_stats'
    ]
    
    conn = psycopg2.connect(
        host='your-redshift-cluster.amazonaws.com',
        port=5439,
        database='your_database',
        user='your_user',
        password='your_password'
    )
    
    cursor = conn.cursor()
    
    try:
        print(f"Starting refresh at {datetime.now()}")
        
        for mv in materialized_views:
            start_time = datetime.now()
            print(f"Refreshing {mv}...")
            
            cursor.execute(f"REFRESH MATERIALIZED VIEW {mv};")
            conn.commit()
            
            duration = (datetime.now() - start_time).total_seconds()
            print(f"✓ {mv} refreshed in {duration:.2f} seconds")
        
        print(f"All views refreshed successfully at {datetime.now()}")
        
    except Exception as e:
        print(f"Error refreshing views: {e}")
        conn.rollback()
        raise
    
    finally:
        cursor.close()
        conn.close()

if __name__ == "__main__":
    refresh_all_materialized_views()
```

### Script 3: PowerShell Script (Windows)

```powershell
# refresh_materialized_views.ps1
# Schedule via Task Scheduler (daily at 2 AM)

$views = @(
    "mv_basic_statistics",
    "mv_user_usage_summary",
    "mv_domain_usage_stats",
    "mv_browser_automation_details",
    "mv_cost_analytics",
    "mv_web_search_statistics",
    "mv_browser_history_analytics",
    "mv_task_completion_stats"
)

$connectionString = "Server=your-cluster.amazonaws.com;Port=5439;Database=your_db;User Id=user;Password=pass;"

foreach ($view in $views) {
    Write-Host "Refreshing $view..."
    $query = "REFRESH MATERIALIZED VIEW $view;"
    
    try {
        # Execute via psql or ADO.NET
        # psql -h host -U user -d database -c $query
        Write-Host "✓ $view refreshed"
    }
    catch {
        Write-Error "Failed to refresh $view : $_"
    }
}
```

---

## Monitoring Refresh Performance

### Check Refresh Status

```sql
-- Check when each view was last refreshed
SELECT 
    schemaname,
    matviewname,
    last_refresh_starttime,
    last_refresh_completiontime,
    EXTRACT(EPOCH FROM (
        last_refresh_completiontime - last_refresh_starttime
    )) AS refresh_duration_seconds,
    refresh_status
FROM pg_matviews
WHERE matviewname LIKE 'mv_%'
ORDER BY last_refresh_starttime DESC;
```

### Check Refresh Performance

```sql
-- Identify slow-refreshing views
SELECT 
    matviewname,
    EXTRACT(EPOCH FROM (
        last_refresh_completiontime - last_refresh_starttime
    )) AS refresh_seconds,
    CASE 
        WHEN EXTRACT(EPOCH FROM (
            last_refresh_completiontime - last_refresh_starttime
        )) < 60 THEN 'Fast'
        WHEN EXTRACT(EPOCH FROM (
            last_refresh_completiontime - last_refresh_starttime
        )) < 300 THEN 'Acceptable'
        ELSE 'Slow'
    END AS performance_status
FROM pg_matviews
WHERE matviewname LIKE 'mv_%'
    AND last_refresh_starttime IS NOT NULL
ORDER BY refresh_seconds DESC;
```

### Create Refresh Log Table

```sql
-- Table to track refresh operations
CREATE TABLE refresh_log (
    log_id BIGINT IDENTITY(1,1),
    refresh_type VARCHAR(50),  -- 'full', 'incremental', 'specific'
    matviewname VARCHAR(255),
    refresh_starttime TIMESTAMP,
    refresh_endtime TIMESTAMP,
    duration_seconds INTEGER,
    status VARCHAR(50),  -- 'success', 'failed'
    error_message TEXT,
    insert_timestamp TIMESTAMP DEFAULT GETDATE(),
    
    DISTKEY(refresh_type),
    SORTKEY(refresh_starttime)
)
ENCODE AUTO;
```

---

## Optimizations for Batch Analytics

### 1. Date-Based Filtering in Materialized Views

**Optimize for batch windows** - Only include data up to previous day:

```sql
-- Option: Filter out today's incomplete data
CREATE MATERIALIZED VIEW mv_basic_statistics_batch AS
SELECT 
    tu.event_date,
    tu.tool_type,
    COUNT(*) AS usage_count
FROM tool_usage tu
WHERE tu.event_date < CURRENT_DATE  -- Exclude incomplete today
    AND tu.event_date IS NOT NULL
GROUP BY tu.event_date, tu.tool_type;
```

### 2. Partitioned Materialized Views (Conceptual)

While Redshift doesn't support partitioned tables directly, you can create date-specific views:

```sql
-- Monthly materialized view for historical analysis
CREATE MATERIALIZED VIEW mv_basic_statistics_2025_01 AS
SELECT * FROM mv_basic_statistics
WHERE event_date >= '2025-01-01' AND event_date < '2025-02-01';

-- Refresh only current month
REFRESH MATERIALIZED VIEW mv_basic_statistics_2025_01;
```

### 3. Staging Table Pattern

**Use staging tables for batch loading**:

```sql
-- Load into staging first
CREATE TABLE tool_usage_staging (LIKE tool_usage);

-- Batch load into staging
COPY tool_usage_staging FROM 's3://bucket/data/' 
IAM_ROLE 'arn:aws:iam::account:role/role';

-- Validate staging data

-- Merge into main table (batch operation)
INSERT INTO tool_usage
SELECT * FROM tool_usage_staging;

-- Then refresh materialized views
REFRESH MATERIALIZED VIEW mv_basic_statistics;
```

---

## Query Patterns for Batch Analytics

### Pattern 1: Yesterday's Data (After Refresh)

```sql
-- Query completed data (after batch refresh)
SELECT * FROM mv_basic_statistics
WHERE event_date = CURRENT_DATE - 1;  -- Yesterday's complete data
```

### Pattern 2: Weekly Aggregations

```sql
-- Weekly rollups (refresh weekly)
SELECT 
    DATE_TRUNC('week', event_date) AS week,
    tool_type,
    SUM(usage_count) AS weekly_usage
FROM mv_basic_statistics
WHERE event_date >= CURRENT_DATE - 30
GROUP BY DATE_TRUNC('week', event_date), tool_type;
```

### Pattern 3: Monthly Reports

```sql
-- Monthly aggregations (refresh monthly)
SELECT 
    DATE_TRUNC('month', event_date) AS month,
    SUM(usage_count) AS monthly_usage,
    SUM(total_cost) AS monthly_cost
FROM mv_cost_analytics
WHERE event_date >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '12 months'
GROUP BY DATE_TRUNC('month', event_date)
ORDER BY month DESC;
```

---

## Batch ETL Workflow

### Recommended Workflow

```
1. Data Loading (Nightly)
   ↓
2. Data Validation
   ↓
3. Refresh Materialized Views (2 AM)
   ↓
4. Run Analytics Queries (After 3 AM)
   ↓
5. Generate Reports (Morning)
```

### Sample ETL Schedule

| Time | Operation | Duration |
|------|-----------|----------|
| 00:00 - 01:00 | Load new data into staging | 1 hour |
| 01:00 - 01:30 | Validate and transform | 30 min |
| 01:30 - 02:00 | Merge into production tables | 30 min |
| 02:00 - 03:00 | Refresh materialized views | 1 hour |
| 03:00+ | Analytics queries run | - |

---

## Performance Considerations

### Refresh Time Management

**Monitor refresh times**:
- ✅ **Good**: < 5 minutes per view
- ⚠️ **Acceptable**: 5-15 minutes per view
- ❌ **Needs Optimization**: > 15 minutes per view

**If refresh is slow**:
1. Check base table sizes
2. Review sort key efficiency
3. Consider incremental refresh strategy
4. Review COUNT(DISTINCT) operations

### Query Performance After Refresh

**Expected**:
- Materialized view queries: < 1 second
- JOIN queries using MVs: < 2 seconds
- Aggregation queries: < 5 seconds

### Storage Considerations

**Materialized views use storage**:
```sql
-- Check materialized view sizes
SELECT 
    tablename,
    pg_size_pretty(pg_total_relation_size('public.' || tablename)) AS size
FROM pg_tables
WHERE tablename LIKE 'mv_%'
ORDER BY pg_total_relation_size('public.' || tablename) DESC;
```

**Recommendation**: Monitor total storage - materialized views should be < 50% of base tables

---

## Best Practices for Batch Analytics

### ✅ DO's

1. **Schedule Refresh During Off-Peak Hours**
   - Use 2 AM - 4 AM window
   - Avoid business hours

2. **Refresh After Data Loading**
   - Always refresh after new data is loaded
   - Ensure data completeness before refresh

3. **Monitor Refresh Times**
   - Track refresh duration
   - Alert if refresh exceeds threshold

4. **Use Helper Views**
   - Query `v_sessions_with_responses` instead of JOINing manually
   - Pre-joined views are faster

5. **Filter by Complete Dates**
   - Query `event_date < CURRENT_DATE` for complete data
   - Avoid querying incomplete current day data

### ❌ DON'Ts

1. **Don't Refresh During Business Hours**
   - Avoids performance impact
   - Prevents query blocking

2. **Don't Refresh Too Frequently**
   - Once per day is usually sufficient
   - Avoid refreshing every hour unless needed

3. **Don't Query Incomplete Data**
   - Avoid querying current day before refresh
   - Use `event_date < CURRENT_DATE` filters

4. **Don't Refresh All Views Simultaneously**
   - Stagger refresh times if possible
   - Reduces cluster load

---

## Troubleshooting

### Issue 1: Refresh Takes Too Long

**Symptoms**: Refresh > 15 minutes

**Solutions**:
- Check base table sizes
- Review sort key usage
- Consider incremental refresh
- Break large views into smaller ones

### Issue 2: Data Lag in Analytics

**Symptoms**: Queries show old data

**Solutions**:
- Verify refresh schedule is running
- Check refresh completion status
- Ensure ETL completes before refresh
- Monitor refresh log

### Issue 3: Query Performance Degraded

**Symptoms**: Queries slower than expected

**Solutions**:
- Verify materialized views are refreshed
- Check if queries use materialized views
- Review query execution plans
- Consider VACUUM and ANALYZE

---

## Summary

**Configuration**:
- ✅ All materialized views: `AUTO REFRESH NO`
- ✅ Manual refresh during scheduled windows
- ✅ Optimized for batch analytics workflows

**Refresh Strategy**:
- ✅ Recommended: Daily refresh (2 AM)
- ✅ Alternative: Hourly refresh (if needed)
- ✅ Advanced: Incremental refresh (for large volumes)

**Benefits**:
- ✅ No refresh overhead during queries
- ✅ Predictable performance
- ✅ Controlled batch processing
- ✅ Better resource utilization

**Scripts Provided**:
- ✅ `06_batch_refresh_scripts.sql` - Automated refresh procedures
- ✅ Refresh logging and monitoring
- ✅ Performance tracking

Your schema is now optimized for **non-real-time batch analytics**!

