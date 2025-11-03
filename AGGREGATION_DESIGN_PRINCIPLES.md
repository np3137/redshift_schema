# Aggregation Design Principles
## Best Practices for Redshift Schema Design

## Core Principle

**Aggregations (COUNT, SUM, AVG, etc.) should be calculated in materialized views, NOT stored in base tables.**

---

## What Should Be in Base Tables?

### ✅ **DO Store in Base Tables:**

1. **Raw Fact Data**
   ```sql
   CREATE TABLE web_searches (
       search_id BIGINT,
       event_timestamp TIMESTAMP,
       num_results INTEGER,  -- ✅ Raw data from source
       ...
   );
   ```

2. **Derived Columns for Performance** (computed from raw data)
   ```sql
   CREATE TABLE tool_usage (
       event_timestamp TIMESTAMP,
       event_date DATE,  -- ✅ Derived: DATE(event_timestamp) - for sort key performance
       ...
   );
   ```

3. **Denormalized Categorical Values** (for JOIN avoidance)
   ```sql
   CREATE TABLE web_automations (
       domain_category VARCHAR(50),  -- ✅ Denormalized: from intent classifier
       ...
   );
   ```

### ❌ **DON'T Store in Base Tables:**

1. **Pre-calculated Aggregations**
   ```sql
   -- ❌ WRONG
   CREATE TABLE web_searches (
       result_count INTEGER,  -- Aggregation - should NOT be here
       total_searches INTEGER,  -- Aggregation - should NOT be here
       ...
   );
   ```

2. **Pre-calculated Sums/Averages**
   ```sql
   -- ❌ WRONG
   CREATE TABLE usage_metrics (
       avg_tokens DOUBLE,  -- Aggregation - should NOT be here
       total_cost_sum DOUBLE,  -- Aggregation - should NOT be here
       ...
   );
   ```

---

## Where Should Aggregations Go?

### ✅ **Materialized Views**

All aggregations should be calculated in materialized views:

```sql
-- ✅ CORRECT
CREATE MATERIALIZED VIEW mv_web_search_statistics AS
SELECT 
    event_date,
    search_type,
    COUNT(*) AS search_count,  -- Aggregation in MV
    COUNT(DISTINCT thread_id) AS unique_threads,  -- Aggregation in MV
    SUM(num_results) AS total_results,  -- Aggregation in MV
    AVG(num_results) AS avg_results  -- Aggregation in MV
FROM web_searches
GROUP BY event_date, search_type;
```

**Benefits:**
- Pre-calculated for fast queries
- Refresh only when needed (batch mode)
- Can be optimized with sort keys
- Single source of truth for aggregations

---

## Examples: Right vs Wrong

### Example 1: Search Statistics

#### ❌ Wrong (Aggregation in Base Table):
```sql
CREATE TABLE web_searches (
    search_id BIGINT,
    event_date DATE,
    search_type VARCHAR(20),
    num_results INTEGER,  -- Raw data - OK
    result_count INTEGER,  -- ❌ WRONG: Pre-calculated COUNT
    ...
);

-- Then query:
SELECT SUM(result_count) FROM web_searches;  -- Wrong pattern
```

#### ✅ Correct (Aggregation in Materialized View):
```sql
-- Base table: Only raw data
CREATE TABLE web_searches (
    search_id BIGINT,
    event_date DATE,
    search_type VARCHAR(20),
    num_results INTEGER,  -- Raw data only
    ...
);

-- Materialized view: Aggregations
CREATE MATERIALIZED VIEW mv_web_search_statistics AS
SELECT 
    event_date,
    search_type,
    COUNT(*) AS search_count,  -- Aggregation here
    SUM(num_results) AS total_results  -- Aggregation here
FROM web_searches
GROUP BY event_date, search_type;

-- Query materialized view:
SELECT SUM(total_results) FROM mv_web_search_statistics;  -- Fast!
```

---

## Design Rationale

### Why NOT Store Aggregations in Base Tables?

1. **Data Integrity Issues**
   - Aggregations can become inconsistent
   - Need to recalculate on every insert/update
   - Risk of stale data

2. **ETL Complexity**
   - Need to calculate during ETL
   - Need to update if underlying data changes
   - More complex ETL logic

3. **Storage Waste**
   - Storing redundant aggregated data
   - Same aggregation calculated multiple times

4. **Maintenance Overhead**
   - Need to keep aggregations in sync
   - Harder to debug inconsistencies

### Why Use Materialized Views?

1. **Single Source of Truth**
   - Aggregations calculated once
   - Always consistent with base data

2. **Performance**
   - Pre-calculated for fast queries
   - Can be refreshed on schedule

3. **Flexibility**
   - Can create different aggregation levels
   - Easy to add new aggregations

4. **Separation of Concerns**
   - Base tables = raw data
   - Materialized views = aggregated data

---

## Redshift-Specific Considerations

### Base Tables Should:
- ✅ Store raw fact data
- ✅ Have optimized sort keys and distribution keys
- ✅ Use appropriate encodings
- ✅ Include derived columns for performance (event_date, domain_category)

### Materialized Views Should:
- ✅ Calculate all aggregations (COUNT, SUM, AVG, etc.)
- ✅ Use AUTO REFRESH NO for batch analytics
- ✅ Use BACKUP NO (can regenerate)
- ✅ Be refreshed during scheduled ETL windows

---

## Migration Example

### Before (Wrong):
```sql
CREATE TABLE web_searches (
    search_id BIGINT,
    result_count INTEGER,  -- ❌ Aggregation in base table
    ...
);

-- ETL needs to calculate
UPDATE web_searches 
SET result_count = (SELECT COUNT(*) FROM search_results WHERE ...);
```

### After (Correct):
```sql
-- Base table: Raw data only
CREATE TABLE web_searches (
    search_id BIGINT,
    num_results INTEGER,  -- ✅ Raw data
    ...
);

-- Materialized view: Aggregations
CREATE MATERIALIZED VIEW mv_web_search_statistics AS
SELECT 
    event_date,
    COUNT(*) AS search_count,
    SUM(num_results) AS total_results
FROM web_searches
GROUP BY event_date;
```

---

## Best Practice Checklist

### Base Tables:
- [ ] Store only raw fact data
- [ ] No pre-calculated COUNT, SUM, AVG fields
- [ ] Derived columns OK (event_date, domain_category for performance)
- [ ] Denormalized categorical values OK (for JOIN avoidance)

### Materialized Views:
- [ ] Calculate all aggregations (COUNT, SUM, AVG, COUNT(DISTINCT))
- [ ] Use AUTO REFRESH NO for batch analytics
- [ ] Refresh during scheduled ETL windows
- [ ] Document what aggregations each view provides

---

## Summary

| Component | Contains | Purpose |
|-----------|----------|---------|
| **Base Tables** | Raw fact data, derived performance columns | Store source data efficiently |
| **Materialized Views** | All aggregations (COUNT, SUM, AVG, etc.) | Pre-calculate for fast analytics queries |

**Key Rule**: If it's an aggregation (COUNT, SUM, AVG, MAX, MIN, COUNT(DISTINCT)), it belongs in a materialized view, NOT in a base table.

