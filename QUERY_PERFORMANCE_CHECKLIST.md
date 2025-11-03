# Redshift Query Performance Checklist

## Quick Reference for Efficient Queries

### ✅ DO's

1. **Always use Materialized Views for Aggregations**
   ```sql
   ✅ SELECT * FROM mv_basic_statistics WHERE event_date >= CURRENT_DATE - 7;
   ❌ SELECT DATE(event_timestamp), COUNT(*) FROM tool_usage GROUP BY DATE(event_timestamp);
   ```

2. **Filter on Sort Key Columns First**
   ```sql
   ✅ WHERE event_timestamp >= '2025-01-01' AND thread_id = 'x' AND tool_type = 'y'
   ❌ WHERE tool_type = 'y' AND event_timestamp >= '2025-01-01'
   ```

3. **Use Specific Column Lists**
   ```sql
   ✅ SELECT session_id, thread_id, event_timestamp FROM tool_usage;
   ❌ SELECT * FROM tool_usage;  -- Especially if TEXT columns exist
   ```

4. **Limit Results When Possible**
   ```sql
   ✅ SELECT * FROM mv_basic_statistics ORDER BY usage_count DESC LIMIT 100;
   ❌ SELECT * FROM mv_basic_statistics ORDER BY usage_count DESC;
   ```

5. **Use DISTKEY in JOINs**
   ```sql
   ✅ JOIN tool_usage tu ON tu.thread_id = um.thread_id  -- thread_id is DISTKEY
   ❌ JOIN tool_usage tu ON tu.session_id = um.session_id  -- session_id is NOT DISTKEY
   ```

### ❌ DON'Ts

1. **Don't Use Functions in WHERE Clauses**
   ```sql
   ❌ WHERE DATE(event_timestamp) = CURRENT_DATE
   ✅ WHERE event_timestamp >= CURRENT_DATE AND event_timestamp < CURRENT_DATE + 1
   ```

2. **Don't Query Base Tables for Aggregations**
   ```sql
   ❌ SELECT COUNT(*) FROM tool_usage GROUP BY DATE(event_timestamp);
   ✅ SELECT * FROM mv_basic_statistics;
   ```

3. **Don't Use ORDER BY on Non-Sort-Key Columns**
   ```sql
   ❌ SELECT * FROM tool_usage ORDER BY session_id;  -- session_id not in sort key
   ✅ SELECT * FROM tool_usage ORDER BY event_timestamp DESC, thread_id;
   ```

4. **Don't Query TEXT Columns Unnecessarily**
   ```sql
   ❌ SELECT * FROM responses;  -- Includes response_content (TEXT)
   ✅ SELECT response_id, thread_id, finish_reason FROM responses;
   ```

5. **Don't Use COUNT(DISTINCT) on High-Cardinality Columns**
   ```sql
   ❌ SELECT COUNT(DISTINCT session_id) FROM tool_usage;  -- Very high cardinality
   ✅ Use materialized view with pre-aggregated counts
   ```

## Query Pattern Efficiency Guide

### Pattern 1: Time-Range Analytics ✅ OPTIMAL
```sql
-- ✅ Best: Use materialized view with date filter
SELECT * FROM mv_basic_statistics
WHERE event_date >= CURRENT_DATE - 30;
```

### Pattern 2: Thread-Specific Queries ✅ OPTIMAL
```sql
-- ✅ Best: Filter on DISTKEY and sort key
SELECT * FROM tool_usage
WHERE thread_id = 'specific_id'
    AND event_timestamp >= CURRENT_DATE - 7;
```

### Pattern 3: Domain Filtering ⚠️ MONITOR
```sql
-- ⚠️ Monitor: May need optimization
SELECT * FROM mv_domain_usage_stats
WHERE domain_category = 'Shopping'
ORDER BY action_count DESC;
```

### Pattern 4: Aggregations Across Time ⚠️ USE MV
```sql
-- ✅ Use materialized view
SELECT 
    SUM(usage_count) AS total,
    SUM(total_cost) AS cost
FROM mv_user_usage_summary
WHERE event_date >= CURRENT_DATE - 7;

-- ❌ Avoid querying base tables
```

### Pattern 5: Multi-Table JOINs ⚠️ CHECK DISTKEYS
```sql
-- ✅ Good: JOIN on DISTKEY columns
SELECT *
FROM tool_usage tu
JOIN usage_metrics um ON tu.thread_id = um.thread_id  -- Both DISTKEY
WHERE tu.event_timestamp >= CURRENT_DATE - 7;

-- ❌ Avoid: JOIN on non-DISTKEY without matching DISTKEY
```

## Materialized View Refresh Monitoring

### Check Refresh Status
```sql
SELECT 
    schemaname,
    matviewname,
    last_refresh_starttime,
    last_refresh_completiontime,
    refresh_status
FROM pg_matviews
WHERE matviewname LIKE 'mv_%'
ORDER BY last_refresh_starttime DESC;
```

### Check Refresh Performance
```sql
SELECT 
    matviewname,
    EXTRACT(EPOCH FROM (last_refresh_completiontime - last_refresh_starttime)) AS refresh_seconds
FROM pg_matviews
WHERE last_refresh_starttime IS NOT NULL
ORDER BY refresh_seconds DESC;
```

## Common Performance Issues & Solutions

### Issue 1: Slow COUNT(DISTINCT)
**Symptom**: Queries with COUNT(DISTINCT) take too long

**Solutions**:
1. Use materialized view with pre-aggregated counts
2. Create separate aggregation table
3. Calculate at insert time (ETL)

### Issue 2: Slow Materialized View Refresh
**Symptom**: AUTO REFRESH takes too long

**Solutions**:
1. Switch to manual refresh (schedule during off-hours)
2. Optimize base table sort keys
3. Reduce COUNT(DISTINCT) in materialized view
4. Break into smaller materialized views

### Issue 3: Slow JOINs
**Symptom**: Multi-table queries are slow

**Solutions**:
1. Ensure JOIN on DISTKEY columns
2. Check sort keys match JOIN conditions
3. Use materialized views to pre-join
4. Consider denormalization for frequently joined data

### Issue 4: High Query Queue Time
**Symptom**: Queries wait in queue before executing

**Solutions**:
1. Use materialized views (faster execution)
2. Query during off-peak hours
3. Consider query prioritization (WLM)
4. Scale up cluster if needed

## Performance Testing Queries

### Test Materialized View vs Base Table
```sql
-- Time this query on base table
EXPLAIN SELECT 
    DATE(event_timestamp),
    tool_type,
    COUNT(*)
FROM tool_usage
GROUP BY DATE(event_timestamp), tool_type;

-- Compare with materialized view
EXPLAIN SELECT * FROM mv_basic_statistics;
```

### Check Query Execution Plan
```sql
-- Get query plan
EXPLAIN SELECT * 
FROM mv_user_usage_summary 
WHERE thread_id = 'test_id';

-- Look for:
-- - Sort (should use sort key)
-- - DS_DIST_NONE (co-located join)
-- - DS_BCAST_INNER (redistribution)
```

## Quick Performance Wins

1. ✅ **Always use materialized views** for common queries
2. ✅ **Filter on sort key columns** first
3. ✅ **Avoid SELECT *** on tables with TEXT
4. ✅ **Use LIMIT** when possible
5. ✅ **Monitor materialized view refresh** times
6. ⚠️ **Check JOIN efficiency** on DISTKEY columns
7. ⚠️ **Monitor COUNT(DISTINCT)** performance

## When to Contact DBA / Optimize Further

- Materialized view refresh > 5 minutes
- COUNT(DISTINCT) queries > 30 seconds
- JOIN queries > 1 minute
- Query queue time consistently high
- Storage costs increasing rapidly

