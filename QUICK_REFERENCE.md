# Redshift Schema Design Quick Reference

## Normalized vs Denormalized: Quick Decision Guide

### ✅ Normalize (Separate Tables) When:
- **Lookup/Reference data** (< 10% of main table size)
- **Large TEXT/JSON fields** (rarely queried)
- **Different access patterns** (one table for aggregations, another for details)
- **Frequently changing data** (avoid update overhead)

**Example**: `domain_classifications`, `responses` (TEXT field)

### ✅ Denormalize (Wide Tables) When:
- **Frequently joined** (>80% of queries join them)
- **Small dimensions** (<10 columns, rarely changes)
- **Expensive aggregations** (pre-calculate COUNT, SUM)
- **Derived columns** (event_date, domain_category)

**Example**: `event_date`, `domain_category`, `result_count` in base tables

---

## Materialized Views: Quick Decision Guide

### ✅ Create Materialized View When:
- **Frequent aggregations** (SUM, COUNT, AVG queried often)
- **Complex JOINs** (multiple tables joined frequently)
- **Expensive calculations** (COUNT(DISTINCT), complex WHERE)
- **Query time > 2 seconds** on base tables
- **Queried > 10 times/day**

### ❌ Don't Create Materialized View When:
- **Simple queries** (already fast on base table)
- **Different filters each time** (can't pre-aggregate)
- **Real-time data needed** (refresh lag)
- **Very high write volume** (refresh overhead too high)

---

## Materialized View Refresh Strategy

### AUTO REFRESH YES
```sql
CREATE MATERIALIZED VIEW mv_name
AUTO REFRESH YES
BACKUP NO
AS SELECT ...;
```
**Use when**: Updates frequent, need near-real-time, refresh < 5 min

### AUTO REFRESH NO (Manual)
```sql
CREATE MATERIALIZED VIEW mv_name
AUTO REFRESH NO
BACKUP NO
AS SELECT ...;

-- Refresh manually
REFRESH MATERIALIZED VIEW mv_name;
```
**Use when**: Updates infrequent, can tolerate lag, refresh > 5 min

---

## Distribution Key Strategy

### Use session_id as DISTKEY When:
- ✅ High cardinality (many unique values)
- ✅ Used in frequent JOINs
- ✅ Even distribution (no data skew)

### Your Schema: ✅ session_id as DISTKEY (Correct)

---

## Sort Key Strategy

### Best Practices:
1. **Time-series**: Date/timestamp as FIRST sort key
   ```sql
   SORTKEY(event_date, thread_id, tool_type)
   ```

2. **Frequently filtered columns** in sort key
   ```sql
   SORTKEY(event_date, domain_category, action_type)
   ```

3. **Avoid functions** in sort key
   ```sql
   -- ❌ Bad
   SORTKEY(DATE(event_timestamp), ...)
   
   -- ✅ Good
   SORTKEY(event_date, ...)  -- event_date populated in ETL
   ```

---

## Your Schema: Design Quality ✅

### Normalization: **Optimal**
- ✅ Lookup tables separated (`domain_classifications`)
- ✅ Large TEXT separated (`responses`)
- ✅ Strategic denormalization (`event_date`, `domain_category`)

### Materialized Views: **Well-Designed**
- ✅ 7 views for common aggregations
- ✅ AUTO REFRESH YES (appropriate)
- ✅ BACKUP NO (appropriate)

### Distribution/Sort Keys: **Optimized**
- ✅ session_id as DISTKEY
- ✅ event_date in sort keys
- ✅ Composite sort keys for filtering

**Verdict**: ✅ **Excellent design - follow these patterns!**

---

## Red Flags (Things to Avoid)

### Schema Design:
- ❌ Over-normalization (too many small tables)
- ❌ Under-normalization (giant table with everything)
- ❌ Low-cardinality DISTKEY (data skew)
- ❌ Functions in sort keys (DATE(), etc.)

### Materialized Views:
- ❌ Too many views (maintenance overhead)
- ❌ Views on simple queries (no benefit)
- ❌ Views needing real-time data (refresh lag)
- ❌ Very large views (refresh takes hours)

---

## Performance Targets

### Materialized View Refresh:
- ✅ **Good**: < 5 minutes
- ⚠️ **Monitor**: 5-15 minutes
- ❌ **Fix**: > 15 minutes

### Query Performance:
- ✅ **Good**: < 1 second (using MV)
- ⚠️ **Acceptable**: 1-5 seconds
- ❌ **Slow**: > 5 seconds

### Storage Efficiency:
- ✅ **Good**: MV size < 50% of base tables
- ⚠️ **Monitor**: 50-100% of base tables
- ❌ **Large**: > 100% of base tables

---

## Quick Checklist

### Schema Design:
- [ ] DISTKEY on high-cardinality column
- [ ] Sort key starts with date/timestamp
- [ ] Large TEXT fields in separate tables
- [ ] Frequently joined data denormalized
- [ ] Lookup tables normalized

### Materialized Views:
- [ ] Only for frequently queried aggregations
- [ ] AUTO REFRESH strategy appropriate
- [ ] BACKUP NO (unless critical)
- [ ] Refresh time < 5 minutes
- [ ] Query performance improvement > 2x

---

## Summary: Your Schema ✅

**Normalization Level**: Perfect hybrid approach
**Materialized Views**: Strategic and well-designed
**Distribution/Sort Keys**: Optimized for performance

**Recommendation**: **No changes needed** - your schema follows Redshift best practices!

