# Redshift Schema Design Best Practices
## Normalization vs Denormalization & Materialized Views

---

## 1. Redshift Architecture Fundamentals

### Key Characteristics:
- **Columnar Storage**: Data stored by columns, not rows
- **Massively Parallel Processing (MPP)**: Data distributed across multiple nodes
- **Shared-Nothing Architecture**: Each node operates independently
- **Optimized for Analytics**: Read-heavy, write-light workloads

### Implications:
- ✅ **Fast aggregations** (SUM, COUNT, AVG on columns)
- ✅ **Excellent compression** (similar values in columns compress well)
- ✅ **Parallel query execution** across nodes
- ⚠️ **JOINs are expensive** (data movement between nodes)
- ⚠️ **Wide tables preferred** (fewer JOINs needed)

---

## 2. Normalized vs Denormalized: The Redshift Perspective

### When to Normalize (Separate Tables) ✅

**Use Normalized Design For:**

1. **Reference/Lookup Data**
   ```sql
   -- ✅ Good: Small lookup table
   CREATE TABLE domain_classifications (
       domain_name VARCHAR(255) NOT NULL,
       domain_category VARCHAR(100) NOT NULL,
       ...
       DISTKEY(domain_name)
   );
   ```
   **Why**: Small, rarely changes, referenced by many tables

2. **One-to-Many Relationships with Different Access Patterns**
   ```sql
   -- ✅ Good: Separate tables for different query patterns
   CREATE TABLE tool_usage (...);  -- Queried for aggregations
   CREATE TABLE web_searches (...);  -- Queried for search-specific analytics
   ```
   **Why**: Different tables optimized for different queries

3. **Large Text/JSON Fields**
   ```sql
   -- ✅ Good: Separate table for large content
   CREATE TABLE responses (
       response_id VARCHAR(255) NOT NULL,
       response_content TEXT,  -- Large field
       ...
   );
   ```
   **Why**: Avoids scanning large TEXT columns unnecessarily

4. **Historical vs Current Data**
   ```sql
   -- ✅ Good: Separate tables by time period
   CREATE TABLE usage_metrics_2024 (...);
   CREATE TABLE usage_metrics_2025 (...);
   ```
   **Why**: Different retention policies, faster queries

**Rules of Thumb**:
- Normalize if lookup table < 10% of main table size
- Normalize if lookup data changes infrequently
- Normalize if main table has high write volume

---

### When to Denormalize (Wide Tables) ✅

**Use Denormalized Design For:**

1. **Frequently Joined Tables**
   ```sql
   -- ✅ Good: Denormalize if always joined together
   CREATE TABLE session_details (
       session_id VARCHAR(255),
       thread_id VARCHAR(255),
       event_timestamp TIMESTAMP,
       model VARCHAR(100),        -- Denormalized from sessions
       total_tokens INTEGER,      -- Denormalized from metrics
       total_cost DOUBLE,         -- Denormalized from metrics
       ...
   );
   ```
   **Why**: Eliminates JOIN overhead

2. **High-Cardinality Dimensions**
   ```sql
   -- ✅ Good: Store domain_category in web_automations
   CREATE TABLE web_automations (
       ...
       domain_name VARCHAR(255),
       domain_category VARCHAR(100),  -- Denormalized
       intent_type VARCHAR(50),       -- Denormalized
       ...
   );
   ```
   **Why**: Avoids JOIN to domain_classifications for every query

3. **Aggregated Metrics**
   ```sql
   -- ✅ Good: Pre-calculate in base table
   CREATE TABLE web_searches (
       ...
       result_count INTEGER,  -- Denormalized: COUNT(search_results)
       ...
   );
   ```
   **Why**: Eliminates expensive COUNT() operations

4. **Time-Based Dimensions**
   ```sql
   -- ✅ Good: Store derived date column
   CREATE TABLE tool_usage (
       event_timestamp TIMESTAMP,
       event_date DATE,  -- Denormalized: DATE(event_timestamp)
       ...
   );
   ```
   **Why**: Better sort key performance, avoids DATE() function

**Rules of Thumb**:
- Denormalize if JOIN happens in >80% of queries
- Denormalize if dimension is small (<10 columns)
- Denormalize if dimension changes infrequently
- Denormalize to avoid expensive aggregations in materialized views

---

## 3. Your Schema Analysis: Normalized vs Denormalized

### Current Approach: **Hybrid (Recommended)** ✅

```
┌─────────────────────────────────────┐
│   Normalized (Separate Tables)     │
├─────────────────────────────────────┤
│ • domain_classifications           │  ← Lookup table
│ • responses                        │  ← Large TEXT field
│ • chat_sessions                    │  ← Session metadata
│ • tool_usage                       │  ← Base event table
│ • web_searches                     │  ← Specialized table
│ • browser_automations              │  ← Specialized table
│ • web_automations                  │  ← Specialized table
└─────────────────────────────────────┘

┌─────────────────────────────────────┐
│   Denormalized (Within Tables)      │
├─────────────────────────────────────┤
│ • event_date                       │  ← DATE(event_timestamp)
│ • domain_category                  │  ← From domain_classifications
│ • result_count                     │  ← COUNT(search_results)
│ • Multiple columns per entity      │  ← Wide tables
└─────────────────────────────────────┘
```

**Why This Works**:
1. ✅ Normalized where needed (lookups, large TEXT)
2. ✅ Denormalized where beneficial (frequently joined dimensions)
3. ✅ Balance between query performance and data consistency

---

## 4. Materialized Views: When and How

### When to Use Materialized Views ✅

#### Use Materialized Views For:

1. **Frequently Queried Aggregations**
   ```sql
   -- ✅ Good: Pre-aggregate daily statistics
   CREATE MATERIALIZED VIEW mv_basic_statistics AS
   SELECT 
       event_date,
       tool_type,
       COUNT(*) AS usage_count,
       COUNT(DISTINCT thread_id) AS unique_threads
   FROM tool_usage
   GROUP BY event_date, tool_type;
   ```
   **Benefit**: 10-100x faster than base table query

2. **Complex JOINs That Are Queried Often**
   ```sql
   -- ✅ Good: Pre-join multiple tables
   CREATE MATERIALIZED VIEW mv_user_usage_summary AS
   SELECT 
       tu.thread_id,
       tu.event_date,
       SUM(um.total_cost) AS total_cost
   FROM tool_usage tu
   JOIN usage_metrics um ON tu.session_id = um.session_id
   GROUP BY tu.thread_id, tu.event_date;
   ```
   **Benefit**: Eliminates JOIN overhead on every query

3. **Expensive Calculations**
   ```sql
   -- ✅ Good: Pre-calculate domain analytics
   CREATE MATERIALIZED VIEW mv_domain_usage_stats AS
   SELECT 
       domain_category,
       COUNT(*) AS action_count,
       COUNT(DISTINCT thread_id) AS unique_threads
   FROM web_automations
   GROUP BY domain_category;
   ```
   **Benefit**: Avoids COUNT(DISTINCT) on every query

4. **Common Filter Patterns**
   ```sql
   -- ✅ Good: Pre-filter by date range
   CREATE MATERIALIZED VIEW mv_recent_activity AS
   SELECT * FROM tool_usage
   WHERE event_date >= CURRENT_DATE - 30;
   ```
   **Benefit**: Faster queries on recent data only

---

### When NOT to Use Materialized Views ❌

#### Avoid Materialized Views For:

1. **Simple Queries on Base Tables**
   ```sql
   -- ❌ Bad: Base table query is already fast
   CREATE MATERIALIZED VIEW mv_all_sessions AS
   SELECT * FROM chat_sessions;
   ```
   **Why**: No benefit, wastes storage

2. **Queries That Change Frequently**
   ```sql
   -- ❌ Bad: Different filters each time
   CREATE MATERIALIZED VIEW mv_filtered_tools AS
   SELECT * FROM tool_usage WHERE tool_type = 'web_search';
   -- But next query needs tool_type = 'browser_automation'
   ```
   **Why**: Need multiple materialized views, overhead not worth it

3. **Very High Write Volume Tables**
   ```sql
   -- ❌ Bad: Table updated every second
   CREATE MATERIALIZED VIEW mv_live_data AS
   SELECT * FROM high_frequency_events;
   ```
   **Why**: Refresh overhead becomes bottleneck

4. **Queries That Need Real-Time Data**
   ```sql
   -- ❌ Bad: Need current second data
   CREATE MATERIALIZED VIEW mv_current_status AS
   SELECT * FROM live_status;
   ```
   **Why**: Materialized views have refresh lag

---

## 5. Materialized View Best Practices

### A. Refresh Strategy

#### AUTO REFRESH YES (Recommended)
```sql
CREATE MATERIALIZED VIEW mv_basic_statistics
AUTO REFRESH YES
AS SELECT ...;
```
**Use When**:
- Base table updates frequently
- Need near-real-time data
- Refresh time < 5 minutes

**Considerations**:
- ✅ Always up-to-date
- ⚠️ Refresh overhead during updates
- ⚠️ May slow down INSERT operations

#### Manual Refresh
```sql
CREATE MATERIALIZED VIEW mv_monthly_summary
AUTO REFRESH NO
AS SELECT ...;

-- Refresh manually
REFRESH MATERIALIZED VIEW mv_monthly_summary;
```
**Use When**:
- Base table updates infrequently
- Can tolerate data lag
- Refresh time > 5 minutes
- Want to control refresh timing (off-hours)

**Considerations**:
- ✅ No overhead during normal operations
- ✅ Can schedule during off-peak hours
- ⚠️ Data may be stale
- ⚠️ Manual management needed

#### Hybrid Approach (Recommended)
```sql
-- Fast-refreshing views: AUTO REFRESH YES
CREATE MATERIALIZED VIEW mv_daily_stats
AUTO REFRESH YES
AS SELECT ...;

-- Slow/expensive views: Manual refresh
CREATE MATERIALIZED VIEW mv_annual_summary
AUTO REFRESH NO
AS SELECT ...;
```

---

### B. Storage Strategy

#### BACKUP NO (Recommended for Most)
```sql
CREATE MATERIALIZED VIEW mv_basic_statistics
BACKUP NO
AS SELECT ...;
```
**Use When**:
- Materialized view can be regenerated
- Base tables are backed up
- Want to save storage costs

**Benefits**:
- ✅ Saves storage (up to 50% reduction)
- ✅ Faster backup operations
- ✅ Can regenerate from base tables

#### BACKUP YES (Rare Cases)
```sql
CREATE MATERIALIZED VIEW mv_critical_summary
BACKUP YES
AS SELECT ...;
```
**Use When**:
- Materialized view refresh is very expensive (>30 minutes)
- Need fast recovery
- Cannot tolerate regeneration time

---

### C. Optimization Strategies

#### 1. Limit Materialized View Scope
```sql
-- ✅ Good: Only last 90 days
CREATE MATERIALIZED VIEW mv_recent_stats AS
SELECT * FROM tool_usage
WHERE event_date >= CURRENT_DATE - 90;
```

#### 2. Pre-Filter in Materialized View
```sql
-- ✅ Good: Filter in MV, not in query
CREATE MATERIALIZED VIEW mv_active_users AS
SELECT * FROM tool_usage
WHERE tool_type IN ('web_search', 'web_automation');
```

#### 3. Use Appropriate Aggregation Level
```sql
-- ✅ Good: Daily aggregation (balance between detail and size)
CREATE MATERIALIZED VIEW mv_daily_stats AS
SELECT 
    event_date,
    tool_type,
    COUNT(*) AS usage_count
FROM tool_usage
GROUP BY event_date, tool_type;
```

#### 4. Avoid Over-Aggregation
```sql
-- ❌ Bad: Too granular (large MV)
CREATE MATERIALIZED VIEW mv_per_session AS
SELECT 
    session_id,
    event_timestamp,
    tool_type,
    COUNT(*) AS count
FROM tool_usage
GROUP BY session_id, event_timestamp, tool_type;

-- ✅ Good: Appropriate granularity
CREATE MATERIALIZED VIEW mv_daily_stats AS
SELECT 
    event_date,
    tool_type,
    COUNT(*) AS usage_count,
    COUNT(DISTINCT session_id) AS unique_sessions
FROM tool_usage
GROUP BY event_date, tool_type;
```

---

## 6. Your Schema: Materialized View Analysis

### Current Materialized Views:

1. **mv_basic_statistics** ✅
   - **Purpose**: Daily aggregations by tool type
   - **Refresh**: AUTO REFRESH YES
   - **Benefit**: 10-100x faster than base table
   - **Storage**: BACKUP NO (can regenerate)

2. **mv_user_usage_summary** ✅
   - **Purpose**: Pre-joined tool_usage + usage_metrics
   - **Refresh**: AUTO REFRESH YES
   - **Benefit**: Eliminates JOIN overhead
   - **Storage**: BACKUP NO

3. **mv_domain_usage_stats** ✅
   - **Purpose**: Domain analytics aggregations
   - **Refresh**: AUTO REFRESH YES
   - **Benefit**: Pre-calculated domain metrics
   - **Storage**: BACKUP NO

4. **mv_cost_analytics** ✅
   - **Purpose**: Cost and token aggregations
   - **Refresh**: AUTO REFRESH YES
   - **Benefit**: Fast cost reporting
   - **Storage**: BACKUP NO

**Assessment**: ✅ **Well-designed** - Appropriate use of materialized views

---

## 7. Redshift Schema Design Checklist

### Normalization Checklist:
- [ ] Separate lookup tables (< 10% of main table)
- [ ] Normalize large TEXT/JSON fields
- [ ] Separate tables with different access patterns
- [ ] Keep reference data normalized

### Denormalization Checklist:
- [ ] Denormalize frequently joined dimensions
- [ ] Store derived columns (event_date, result_count)
- [ ] Denormalize small, rarely-changing dimensions
- [ ] Pre-calculate aggregations in base tables

### Materialized View Checklist:
- [ ] Create for frequently queried aggregations
- [ ] Use AUTO REFRESH YES for frequently updated data
- [ ] Use BACKUP NO for most views (can regenerate)
- [ ] Pre-filter in materialized view when possible
- [ ] Monitor refresh times (should be < 5 minutes)
- [ ] Limit scope to commonly queried time ranges

### Distribution Key Checklist:
- [ ] Use high-cardinality columns
- [ ] Match DISTKEY in frequently joined tables
- [ ] Avoid low-cardinality columns (data skew)
- [ ] Use session_id or thread_id for transactional data

### Sort Key Checklist:
- [ ] Include timestamp/date as first sort key for time-series
- [ ] Add frequently filtered columns to sort key
- [ ] Keep sort keys selective (not too many columns)
- [ ] Use event_date instead of DATE(event_timestamp)

---

## 8. Decision Framework

### Should I Normalize or Denormalize?

```
Is it a lookup/reference table?
├─ YES → Normalize (separate table)
└─ NO
    │
    Is it frequently joined?
    ├─ YES → Denormalize (store in main table)
    └─ NO
        │
        Does it change frequently?
        ├─ YES → Normalize (avoid update overhead)
        └─ NO → Denormalize (simpler queries)
```

### Should I Create a Materialized View?

```
Is it an aggregation query?
├─ NO → Don't create materialized view
└─ YES
    │
    Is it queried frequently (>10 times/day)?
    ├─ NO → Don't create materialized view
    └─ YES
        │
        Is base query slow (>5 seconds)?
        ├─ NO → Don't create materialized view
        └─ YES → Create materialized view
```

---

## 9. Common Anti-Patterns to Avoid

### ❌ Anti-Pattern 1: Over-Normalization
```sql
-- ❌ Bad: Too many tables for simple data
CREATE TABLE sessions (...);
CREATE TABLE session_metadata (...);
CREATE TABLE session_timestamps (...);
CREATE TABLE session_status (...);
```
**Problem**: Too many JOINs, poor performance
**Solution**: Combine into fewer tables

### ❌ Anti-Pattern 2: Under-Normalization
```sql
-- ❌ Bad: All data in one giant table
CREATE TABLE everything (
    session_id, thread_id, event_timestamp,
    response_content TEXT,  -- 10KB per row
    reasoning_steps JSON,   -- 5KB per row
    search_results JSON,    -- 20KB per row
    ...
);
```
**Problem**: Scanning large columns unnecessarily
**Solution**: Separate large TEXT/JSON fields

### ❌ Anti-Pattern 3: Too Many Materialized Views
```sql
-- ❌ Bad: Materialized view for every possible query
CREATE MATERIALIZED VIEW mv_tool_type_web_search (...);
CREATE MATERIALIZED VIEW mv_tool_type_browser (...);
CREATE MATERIALIZED VIEW mv_tool_type_agent (...);
CREATE MATERIALIZED VIEW mv_date_today (...);
CREATE MATERIALIZED VIEW mv_date_yesterday (...);
-- ... 50 more views
```
**Problem**: Maintenance overhead, storage waste
**Solution**: Create views only for frequently used patterns

### ❌ Anti-Pattern 4: Materialized View on Simple Queries
```sql
-- ❌ Bad: MV for simple filter
CREATE MATERIALIZED VIEW mv_web_searches AS
SELECT * FROM tool_usage WHERE tool_type = 'web_search';
```
**Problem**: Base query already fast, MV overhead not worth it
**Solution**: Query base table directly

---

## 10. Summary: Your Schema Design

### Normalization Level: **Optimal** ✅

**Normalized (Separate Tables)**:
- ✅ `domain_classifications` - Lookup table
- ✅ `responses` - Large TEXT field
- ✅ Specialized tables (web_searches, browser_automations, etc.)

**Denormalized (Within Tables)**:
- ✅ `event_date` - Derived column
- ✅ `domain_category` - Frequently joined dimension
- ✅ `result_count` - Pre-calculated aggregation

**Materialized Views**:
- ✅ 7 materialized views for common aggregations
- ✅ AUTO REFRESH YES for all (appropriate)
- ✅ BACKUP NO for all (appropriate)
- ✅ Pre-filtered where beneficial

### Recommendations for Your Schema:

1. ✅ **Current Design is Excellent** - Hybrid approach is optimal
2. ✅ **Materialized Views are Well-Chosen** - All address real performance needs
3. ✅ **Denormalization is Strategic** - event_date, domain_category, result_count
4. ✅ **Normalization is Appropriate** - Large TEXT and lookups separated

**No Changes Needed** - Your schema follows Redshift best practices!

---

## 11. Performance Monitoring

### Monitor Materialized View Health:
```sql
-- Check refresh times
SELECT 
    matviewname,
    last_refresh_starttime,
    last_refresh_completiontime,
    EXTRACT(EPOCH FROM (last_refresh_completiontime - last_refresh_starttime)) AS refresh_seconds
FROM pg_matviews
WHERE refresh_seconds > 300;  -- Flag views taking > 5 minutes
```

### Monitor Query Performance:
```sql
-- Compare materialized view vs base table
-- If MV is < 2x faster, consider removing it
EXPLAIN SELECT * FROM mv_basic_statistics WHERE event_date = CURRENT_DATE;
EXPLAIN SELECT DATE(event_timestamp), tool_type, COUNT(*) 
FROM tool_usage 
GROUP BY DATE(event_timestamp), tool_type;
```

### Monitor Storage:
```sql
-- Check materialized view sizes
SELECT 
    schemaname,
    tablename,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS size
FROM pg_tables
WHERE tablename LIKE 'mv_%'
ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC;
```

---

## Conclusion

**Your Schema Design**: ✅ **Excellent**

- Balanced normalization/denormalization
- Strategic use of materialized views
- Appropriate distribution and sort keys
- Efficient column design

**Key Takeaways**:
1. **Hybrid approach** is best for Redshift
2. **Denormalize** frequently joined dimensions
3. **Normalize** large TEXT fields and lookups
4. **Materialized views** for aggregations and complex JOINs
5. **Monitor** refresh times and query performance

