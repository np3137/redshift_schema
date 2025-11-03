# Redshift Schema Efficiency Guide
## Materialized Views & Query Optimization

---

## 1. Current Schema Efficiency Analysis

### ✅ **What's Good:**

1. **Distribution Keys**: All tables use `thread_id` as DISTKEY
   - ✅ Consistent across tables for join efficiency
   - ✅ High cardinality column
   - ✅ Matches common join patterns

2. **Sort Keys**: Composite sort keys with timestamp first
   - ✅ Time-series queries optimized
   - ✅ Most selective columns included

3. **Materialized View Design**: Using AUTO REFRESH YES
   - ✅ Automatic updates
   - ✅ BACKUP NO saves storage

### ⚠️ **Potential Issues & Improvements:**

1. **Materialized View JOIN Efficiency**
   - `mv_user_usage_summary` joins `tool_usage` with `usage_metrics` without matching distribution keys in JOIN condition
   - Could cause data movement during refresh

2. **COUNT(DISTINCT) Performance**
   - Multiple COUNT(DISTINCT) in materialized views can be expensive
   - Consider pre-aggregation strategy

3. **COALESCE in GROUP BY**
   - Using COALESCE in GROUP BY clauses can prevent optimal sort key usage

4. **Subquery in Materialized View**
   - `mv_web_search_statistics` has subquery which may not optimize well

---

## 2. Critical Considerations for Materialized Views

### A. Distribution Key Matching in JOINs

**Problem**: When materialized views join tables, Redshift must redistribute data if JOIN columns don't match distribution keys.

**Best Practice**:
- Join on DISTKEY columns when possible
- If JOINing on non-DISTKEY, ensure sort keys can help

**Example Issue in Current Schema**:
```sql
-- mv_user_usage_summary joins on session_id and thread_id
FROM tool_usage tu
LEFT JOIN usage_metrics um ON tu.session_id = um.session_id 
    AND tu.thread_id = um.thread_id
```
✅ **This is GOOD** - Both tables have `thread_id` as DISTKEY and it's in the JOIN condition.

### B. Sort Key Efficiency in Materialized Views

**Materialized views inherit sort/distribution from the base query, BUT:**

⚠️ **Issue**: DATE() function in GROUP BY breaks sort key benefits
```sql
GROUP BY DATE(event_timestamp), tool_type
```
- Redshift can't use sort key on `event_timestamp` because we're grouping by `DATE(event_timestamp)`
- This is often unavoidable for time-series aggregation

**Solution Options**:
1. Keep as-is (DATE() is necessary for daily aggregation)
2. Add `event_date` column to base tables (requires ETL change)
3. Use INTERLEAVED sort keys if multiple columns have equal selectivity

### C. COUNT(DISTINCT) Performance

**Warning**: COUNT(DISTINCT) is expensive in Redshift, especially in materialized views.

**Current Usage**:
```sql
COUNT(DISTINCT thread_id) AS unique_threads,
COUNT(DISTINCT session_id) AS unique_sessions
```

**Recommendations**:
1. ✅ Keep for low-cardinality dimensions (like date)
2. ⚠️ Consider caching if high-cardinality
3. Consider separate tables for distinct counts if very expensive

### D. AUTO REFRESH Behavior

**Important Points**:
- `AUTO REFRESH YES` refreshes automatically when base tables are updated
- Refresh happens **incrementally** when possible
- Full refresh happens when structure changes
- **Performance Impact**: Refresh can block queries (minimal with incremental)

**Monitoring**:
```sql
-- Check materialized view refresh status
SELECT 
    schemaname,
    matviewname,
    last_refresh_starttime,
    last_refresh_completiontime,
    refresh_status
FROM pg_matviews;
```

### E. Materialized View Storage

**Current**: `BACKUP NO` on all materialized views
- ✅ Saves storage (can be regenerated)
- ✅ Fine for analytics views
- ⚠️ Consider `BACKUP YES` for critical production views if regeneration time is significant

---

## 3. Query Optimization Best Practices

### A. Always Query Materialized Views When Possible

**Instead of**:
```sql
SELECT 
    DATE(event_timestamp) AS event_date,
    tool_type,
    COUNT(*) AS usage_count
FROM tool_usage
GROUP BY DATE(event_timestamp), tool_type;
```

**Use**:
```sql
SELECT * FROM mv_basic_statistics 
WHERE event_date >= CURRENT_DATE - 7;
```

### B. Use WHERE Clauses on Sort Keys

**Optimal**:
```sql
-- Uses sort key on event_timestamp
SELECT * FROM tool_usage 
WHERE event_timestamp >= '2025-01-01'
    AND thread_id = 'specific_thread';
```

**Suboptimal**:
```sql
-- Can't use sort key efficiently
SELECT * FROM tool_usage 
WHERE tool_type = 'web_search';  -- tool_type is 3rd in sort key
```

### C. Avoid SELECT * When Possible

- Redshift must decompress and return all columns
- Specify only needed columns
- Especially important for tables with TEXT fields

### D. LIMIT Early in Queries

**Good**:
```sql
SELECT * FROM (
    SELECT * FROM mv_basic_statistics 
    ORDER BY usage_count DESC
) LIMIT 10;
```

### E. Avoid Functions in WHERE Clauses

**Bad**:
```sql
WHERE DATE(event_timestamp) = CURRENT_DATE
```

**Good**:
```sql
WHERE event_timestamp >= CURRENT_DATE 
    AND event_timestamp < CURRENT_DATE + 1
```

---

## 4. Schema-Specific Recommendations

### Issue 1: Materialized View JOIN Efficiency

**Current** - `mv_user_usage_summary`:
```sql
FROM tool_usage tu
LEFT JOIN usage_metrics um ON tu.session_id = um.session_id 
    AND tu.thread_id = um.thread_id
```

**Analysis**: ✅ This is efficient because:
- Both tables use `thread_id` as DISTKEY
- JOIN includes DISTKEY column (`thread_id`)
- Redshift can use co-location join strategy

### Issue 2: COUNT(DISTINCT) in Materialized Views

**Considerations**:
- COUNT(DISTINCT thread_id) - Usually low-medium cardinality per day ✅ OK
- COUNT(DISTINCT session_id) - Can be high cardinality ⚠️ Monitor

**Recommendation**: Monitor query performance. If slow, consider:
- Separate materialized view for distinct counts
- Pre-aggregate at insert time (requires ETL change)

### Issue 3: Subquery in Materialized View

**Current** - `mv_web_search_statistics`:
```sql
LEFT JOIN (
    SELECT search_id, COUNT(*) AS result_count
    FROM search_results
    GROUP BY search_id
) sr_count ON ws.search_id = sr_count.search_id
```

**Analysis**: ⚠️ This subquery executes during each refresh. Consider:
- Creating intermediate materialized view
- Or calculating at insert time in ETL

**Alternative Approach**:
```sql
-- Option: Add result_count column to web_searches (calculated at insert)
-- Then materialized view becomes simpler:
SELECT 
    DATE(event_timestamp) AS event_date,
    search_type,
    COUNT(*) AS search_count,
    SUM(result_count) AS total_results_returned
FROM web_searches
GROUP BY DATE(event_timestamp), search_type;
```

### Issue 4: COALESCE in GROUP BY

**Current** - `mv_domain_usage_stats`:
```sql
GROUP BY 
    COALESCE(dc.domain_category, wa.domain_category, 'Unknown'),
    ...
```

**Impact**: 
- Prevents use of sort keys on original columns
- Redshift must evaluate COALESCE for every row

**Recommendation**: 
- ✅ Keep as-is if domain_category needs normalization
- ⚠️ Consider ETL to populate domain_category consistently in base table
- This would allow sort key usage

---

## 5. Performance Monitoring Queries

### Check Materialized View Sizes
```sql
SELECT 
    schemaname,
    tablename,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS size
FROM pg_tables
WHERE tablename LIKE 'mv_%'
ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC;
```

### Check Query Performance
```sql
-- Enable query monitoring
SELECT 
    query,
    starttime,
    endtime,
    total_queue_time,
    execution_time,
    query_scan_size
FROM stl_query
WHERE userid = CURRENT_USER
ORDER BY starttime DESC
LIMIT 10;
```

### Check Sort Key Efficiency
```sql
SELECT 
    schemaname,
    tablename,
    sortkey_num,
    sortkey1,
    sortkey1_enc,
    sortkey_num,
    unsorted
FROM svv_table_info
WHERE schemaname = 'public'
ORDER BY unsorted DESC;
```

---

## 6. Optimization Recommendations Summary

### High Priority

1. **Monitor Materialized View Refresh Times**
   - Check `pg_matviews` regularly
   - If refresh takes too long, consider manual refresh strategy

2. **Add Indexes on Frequently Filtered Columns**
   - Redshift doesn't have traditional indexes, but sort keys act as indexes
   - Ensure frequently filtered columns are in sort keys

3. **Consider Pre-aggregation in ETL**
   - Calculate `event_date` at insert time
   - Store `result_count` in `web_searches` table
   - Normalize `domain_category` in base tables

### Medium Priority

1. **Review COUNT(DISTINCT) Performance**
   - Monitor query times
   - Consider separate aggregation tables if slow

2. **Optimize Large Text Fields**
   - `response_content` (TEXT) - only query when needed
   - Consider compression on TEXT fields
   - Store in separate table (already done ✅)

### Low Priority / Future

1. **Interleaved Sort Keys**
   - If multiple columns have equal selectivity
   - Test performance vs composite sort keys

2. **Table Partitioning**
   - For very large tables (requires Redshift Spectrum)
   - Consider date-based partitioning

---

## 7. Recommended Schema Improvements

### Improvement 1: Add event_date Column

**Benefit**: Allows sort key usage for date-based queries

```sql
ALTER TABLE tool_usage 
ADD COLUMN event_date DATE GENERATED ALWAYS AS (DATE(event_timestamp)) STORED;

-- Then update sort key
ALTER TABLE tool_usage 
ALTER SORTKEY (event_date, thread_id, tool_type);
```

**Note**: Requires Redshift column generation support (check version)

### Improvement 2: Denormalize Domain Category

**Benefit**: Avoids COALESCE in materialized views

In ETL, ensure `web_automations.domain_category` is always populated from `domain_classifications` lookup. Then materialized view becomes:

```sql
SELECT 
    wa.domain_category,  -- No COALESCE needed
    wa.domain_name,
    DATE(wa.event_timestamp) AS event_date,
    ...
FROM web_automations wa
WHERE wa.domain_category IS NOT NULL
GROUP BY wa.domain_category, wa.domain_name, DATE(wa.event_timestamp), wa.action_type;
```

### Improvement 3: Add result_count to web_searches

**Benefit**: Eliminates subquery in materialized view

```sql
ALTER TABLE web_searches 
ADD COLUMN result_count INTEGER;

-- Calculate in ETL or via trigger
-- Then materialized view becomes simpler without subquery
```

---

## 8. Query Pattern Recommendations

### Pattern 1: Time-Range Queries (Optimal)

```sql
-- ✅ Optimal: Uses sort key
SELECT * FROM mv_basic_statistics
WHERE event_date >= CURRENT_DATE - 30
    AND event_date < CURRENT_DATE;
```

### Pattern 2: Thread-Specific Queries (Optimal)

```sql
-- ✅ Optimal: Uses DISTKEY and sort key
SELECT * FROM tool_usage
WHERE thread_id = 'specific_id'
    AND event_timestamp >= CURRENT_DATE - 7;
```

### Pattern 3: Domain Analytics (Monitor)

```sql
-- ⚠️ May need optimization if slow
SELECT * FROM mv_domain_usage_stats
WHERE domain_category = 'Shopping'
ORDER BY action_count DESC;
```

### Pattern 4: Aggregations (Use Materialized Views)

```sql
-- ✅ Use materialized view
SELECT 
    SUM(usage_count) AS total,
    SUM(total_cost) AS cost
FROM mv_user_usage_summary
WHERE event_date >= CURRENT_DATE - 7;

-- ❌ Don't query base tables for this
```

---

## 9. Materialized View Refresh Strategy

### Current: AUTO REFRESH YES

**Pros**:
- Always up-to-date
- No manual intervention

**Cons**:
- Refresh overhead during updates
- May slow down inserts if refresh is heavy

### Alternative: Manual Refresh

If AUTO REFRESH becomes a bottleneck:

```sql
-- Change to manual refresh
ALTER MATERIALIZED VIEW mv_basic_statistics 
SET AUTO REFRESH NO;

-- Refresh manually (schedule via cron/job)
REFRESH MATERIALIZED VIEW mv_basic_statistics;
```

**Best Practice**: Start with AUTO REFRESH, monitor performance, switch to manual if needed.

---

## 10. Final Checklist

- [ ] ✅ Distribution keys match join patterns
- [ ] ✅ Sort keys include frequently filtered columns
- [ ] ✅ Materialized views use AUTO REFRESH
- [ ] ⚠️ Monitor COUNT(DISTINCT) performance
- [ ] ⚠️ Consider denormalizing domain_category in ETL
- [ ] ⚠️ Monitor subquery performance in materialized views
- [ ] ✅ Use materialized views for aggregations
- [ ] ✅ Avoid SELECT * on tables with TEXT fields
- [ ] ⚠️ Consider adding event_date column
- [ ] ⚠️ Monitor materialized view refresh times

---

## Conclusion

**Current Schema Efficiency**: **7.5/10**

**Strengths**:
- Good distribution key strategy
- Appropriate sort keys
- Proper use of materialized views

**Improvements Needed**:
- Monitor COUNT(DISTINCT) performance
- Consider ETL optimizations to eliminate COALESCE
- Monitor subquery in materialized view
- Consider pre-aggregation strategies

**Overall Assessment**: The schema is well-designed for Redshift. Monitor performance in production and optimize based on actual query patterns and data volumes.

