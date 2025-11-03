# Redshift Schema Efficiency Summary

## Executive Summary

**Current Schema Efficiency Rating: 7.5/10**

Your schema is **well-designed** for Redshift with good distribution and sort key strategy. However, there are **optimization opportunities** that can improve materialized view and query performance.

---

## Key Findings

### ✅ **Strengths**

1. **Distribution Keys**: Consistent use of `thread_id` as DISTKEY across all tables
   - Enables efficient co-located joins
   - High cardinality column
   - Matches common query patterns

2. **Sort Keys**: Composite sort keys with timestamp first
   - Optimized for time-series queries
   - Includes most selective columns

3. **Materialized View Strategy**: Proper use of AUTO REFRESH YES
   - Automatic updates
   - BACKUP NO saves storage

### ⚠️ **Areas for Improvement**

1. **COUNT(DISTINCT) Performance** - Multiple COUNT(DISTINCT) in materialized views
   - Monitor performance in production
   - Consider pre-aggregation if slow

2. **COALESCE in GROUP BY** - Used in `mv_domain_usage_stats`
   - Prevents optimal sort key usage
   - Consider ETL denormalization

3. **Subquery in Materialized View** - `mv_web_search_statistics` has subquery
   - May impact refresh performance
   - Consider storing result_count in base table

4. **DATE() Function in GROUP BY** - Breaks sort key benefits
   - Unavoidable for time-series aggregation
   - Consider adding event_date column

---

## Immediate Action Items

### Priority 1: Monitor Performance (Week 1)

1. **Monitor Materialized View Refresh Times**
   ```sql
   SELECT matviewname, 
          EXTRACT(EPOCH FROM (last_refresh_completiontime - last_refresh_starttime)) AS refresh_seconds
   FROM pg_matviews
   WHERE matviewname LIKE 'mv_%';
   ```

2. **Track Query Performance**
   - Identify slow queries (> 5 seconds)
   - Check if materialized views are being used
   - Monitor COUNT(DISTINCT) execution times

### Priority 2: ETL Optimizations (Week 2-3)

1. **Denormalize Domain Category**
   - Populate `web_automations.domain_category` in ETL
   - Eliminates COALESCE in materialized view
   - Allows better sort key usage

2. **Add result_count to web_searches**
   - Calculate in ETL when inserting search results
   - Eliminates subquery in materialized view
   - Improves refresh performance

3. **Consider Adding event_date Column** (Optional)
   ```sql
   ALTER TABLE tool_usage 
   ADD COLUMN event_date DATE;
   -- Populate in ETL: event_date = DATE(event_timestamp)
   ```
   - Allows direct sort key usage on date
   - Improves date-range query performance

### Priority 3: Query Optimization (Ongoing)

1. **Always Use Materialized Views for Aggregations**
   - Don't query base tables for COUNT, SUM, AVG
   - Use materialized views even for simple aggregations

2. **Filter on Sort Keys First**
   - Put timestamp filters first in WHERE clause
   - Follow with DISTKEY column filters

3. **Avoid SELECT ***
   - Especially on tables with TEXT columns
   - Specify only needed columns

---

## Schema-Specific Recommendations

### Table: `tool_usage`
**Current**: ✅ Good DISTKEY and SORTKEY
**Recommendation**: 
- Consider adding `event_date` column for better date queries
- Monitor COUNT(DISTINCT) performance in materialized views

### Table: `web_automations`
**Current**: ✅ Good DISTKEY and SORTKEY
**Recommendation**:
- **CRITICAL**: Ensure `domain_category` is populated in ETL
- This eliminates COALESCE in materialized view GROUP BY
- Allows better sort key optimization

### Table: `web_searches`
**Current**: ✅ Good DISTKEY and SORTKEY
**Recommendation**:
- Add `result_count` column (calculated in ETL)
- Eliminates subquery in `mv_web_search_statistics`
- Improves refresh performance

### Table: `usage_metrics`
**Current**: ✅ Good DISTKEY and SORTKEY
**Recommendation**:
- No changes needed
- JOINs with other tables are efficient (matching DISTKEY)

### Materialized View: `mv_user_usage_summary`
**Current**: ✅ JOIN on matching DISTKEY columns
**Recommendation**:
- Monitor COUNT(DISTINCT) performance
- Consider separate aggregation if slow

### Materialized View: `mv_domain_usage_stats`
**Current**: ⚠️ Uses COALESCE in GROUP BY
**Recommendation**:
- **HIGH PRIORITY**: Populate `domain_category` in ETL
- Switch to optimized version: `mv_domain_usage_stats_opt`
- Eliminates COALESCE, improves performance

### Materialized View: `mv_web_search_statistics`
**Current**: ⚠️ Contains subquery
**Recommendation**:
- Add `result_count` to `web_searches` table
- Switch to optimized version: `mv_web_search_statistics_opt`
- Eliminates subquery, faster refresh

---

## Expected Performance Improvements

### After ETL Optimizations:

1. **Domain Category Denormalization**
   - **Impact**: 20-30% faster refresh on `mv_domain_usage_stats`
   - **Effort**: Low (update ETL pipeline)
   - **Risk**: Low

2. **Result Count Pre-calculation**
   - **Impact**: 30-40% faster refresh on `mv_web_search_statistics`
   - **Effort**: Low (update ETL pipeline)
   - **Risk**: Low

3. **Event Date Column Addition**
   - **Impact**: 10-15% faster date-range queries
   - **Effort**: Medium (schema change + ETL update)
   - **Risk**: Low (additive change)

### Query Performance Improvements:

- **Using Materialized Views**: 10-100x faster than base table queries
- **Proper Sort Key Usage**: 2-5x faster filtering
- **DISTKEY JOIN Optimization**: 3-10x faster joins

---

## Monitoring Dashboard Queries

### Materialized View Health
```sql
SELECT 
    matviewname,
    last_refresh_starttime,
    last_refresh_completiontime,
    EXTRACT(EPOCH FROM (last_refresh_completiontime - last_refresh_starttime)) AS refresh_seconds,
    refresh_status
FROM pg_matviews
WHERE matviewname LIKE 'mv_%'
ORDER BY last_refresh_starttime DESC;
```

### Table Sizes
```sql
SELECT 
    schemaname,
    tablename,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS size,
    pg_size_pretty(pg_relation_size(schemaname||'.'||tablename)) AS table_size,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename) - pg_relation_size(schemaname||'.'||tablename)) AS indexes_size
FROM pg_tables
WHERE schemaname = 'public'
ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC;
```

### Sort Key Efficiency
```sql
SELECT 
    schemaname,
    tablename,
    sortkey_num,
    sortkey1,
    unsorted
FROM svv_table_info
WHERE schemaname = 'public'
ORDER BY unsorted DESC;
```

---

## Best Practices Checklist

### Schema Design ✅
- [x] Distribution keys match join patterns
- [x] Sort keys include frequently filtered columns
- [x] Appropriate column encoding (ENCODE AUTO)
- [x] Proper data types

### Materialized Views ✅
- [x] AUTO REFRESH YES for automatic updates
- [x] BACKUP NO for storage efficiency
- [ ] COALESCE eliminated (needs ETL change)
- [ ] Subqueries eliminated (needs ETL change)

### Query Patterns ⚠️
- [ ] Always use materialized views for aggregations
- [ ] Filter on sort key columns first
- [ ] Avoid SELECT * on TEXT columns
- [ ] Use LIMIT when possible

### Monitoring ⚠️
- [ ] Track materialized view refresh times
- [ ] Monitor COUNT(DISTINCT) performance
- [ ] Check query execution plans
- [ ] Track table sizes

---

## Implementation Roadmap

### Phase 1: Monitoring (Week 1)
1. Deploy current schema
2. Monitor materialized view refresh times
3. Track query performance
4. Identify bottlenecks

### Phase 2: ETL Optimizations (Week 2-3)
1. Populate `domain_category` in ETL
2. Add `result_count` calculation in ETL
3. Test optimized materialized views
4. Deploy optimized views

### Phase 3: Advanced Optimizations (Month 2+)
1. Add `event_date` column if needed
2. Create thread-level materialized views
3. Optimize COUNT(DISTINCT) if needed
4. Fine-tune based on production patterns

---

## Conclusion

Your schema is **production-ready** with **good fundamentals**. The optimizations recommended are **incremental improvements** that will enhance performance as data volume grows.

**Key Takeaways**:
1. ✅ Current design is solid - deploy with confidence
2. ⚠️ Monitor performance in production
3. 🔧 Implement ETL optimizations for domain_category and result_count
4. 📊 Use materialized views for all aggregations
5. 🔍 Monitor and tune based on actual usage patterns

**Risk Level**: **LOW** - All optimizations are additive and can be implemented incrementally.

