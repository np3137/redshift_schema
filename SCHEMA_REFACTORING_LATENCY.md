# Schema Refactoring Summary - Latency Analysis Enhancement

## Overview

This document summarizes the schema refactoring done to add comprehensive latency analysis capabilities and remove unused parameters.

## Changes Made

### 1. Added Latency Timestamps

#### `usage_metrics` Table
- ✅ Added `request_timestamp TIMESTAMP` - When request was sent to AI service
- ✅ Added `response_timestamp TIMESTAMP` - When response was received
- **Purpose**: Enable accurate latency calculation from timestamps, time-of-day analysis, and performance correlation

#### `chat_sessions` Table
- ✅ Added `request_timestamp TIMESTAMP` - When user request was received
- **Purpose**: Enable session-level latency tracking and correlation with task completion

### 2. Enhanced Materialized Views

#### `mv_cost_analytics`
- ✅ Added `avg_calculated_latency_ms` - Calculated from timestamps (more accurate)
- ✅ Added `median_latency_ms` - Median latency percentile
- ✅ Added `p95_latency_ms` - 95th percentile latency
- ✅ Kept `avg_reported_latency_ms` - For comparison/validation

#### `mv_user_usage_summary`
- ✅ Added `avg_latency_ms` - Average latency per user/tool combination

#### `mv_latency_analytics` (NEW)
- ✅ Comprehensive latency analysis materialized view
- Includes: time-of-day patterns, model comparison, cost correlation
- Metrics: avg, median, p95, p99 latencies
- Correlations: cost per request, tokens per request, session latency

### 3. Enhanced Helper Views

#### `v_tool_usage_details`
- ✅ Added `calculated_latency_ms` - Calculated from timestamps
- ✅ Added `request_timestamp` and `response_timestamp` columns
- ✅ Kept `reported_latency_ms` for comparison

#### `v_latency_analysis` (NEW)
- ✅ Comprehensive latency analysis view
- Includes: calculated latency, time-of-day metrics, cost/token correlation
- Features: session-level latency, tool context, task completion context

### 4. Updated Query Examples

Added comprehensive latency analysis queries:
- Comprehensive latency analysis by model
- Time-of-day performance patterns
- Latency impact on task completion
- Model performance comparison
- Tool-specific latency analysis
- Cost-latency correlation
- Latency by domain category
- Daily latency trends
- Request/response timestamp validation

### 5. Updated ETL Requirements

- ✅ Added section for latency timestamp population
- ✅ Provided Python examples for extracting request/response timestamps
- ✅ Documented why latency timestamps are critical
- ✅ Explained latency calculation formula

### 6. Removed Unused References

- ✅ Removed references to `mv_browser_history_analytics` (non-existent view)
- ✅ Cleaned up query examples that referenced non-existent tables/views

## Benefits

### Analysis Capabilities Enabled

1. **Accurate Latency Measurement**
   - Calculate latency directly from timestamps (more reliable than pre-calculated values)
   - Validate reported latency against calculated latency

2. **Time-of-Day Analysis**
   - Identify peak hours with slower response times
   - Understand performance patterns throughout the day
   - Plan capacity based on usage patterns

3. **Model Performance Comparison**
   - Compare actual response times by model
   - Identify which models perform better/faster
   - Make informed decisions about model selection

4. **Cost-Latency Correlation**
   - Understand relationship between latency and costs
   - Identify if longer latencies correlate with higher costs
   - Optimize cost/performance trade-offs

5. **User Experience Analysis**
   - Correlate latency with task completion rates
   - Identify if slower responses lead to lower completion
   - Set SLA thresholds based on actual data

6. **Tool-Specific Analysis**
   - Understand latency by tool type
   - Identify which tools are slower
   - Optimize tool performance

7. **Anomaly Detection**
   - Flag latency discrepancies (reported vs calculated)
   - Identify latency spikes
   - Monitor for performance degradation

## ETL Requirements

### Critical: Must Populate

1. **usage_metrics.request_timestamp**
   - Source: `request_body.timestamp`, `@timestamp`, or system log
   - When: When request was sent to AI service

2. **usage_metrics.response_timestamp**
   - Source: `response_body.created`, `response_body.timestamp`, or system log
   - When: When response was received

3. **chat_sessions.request_timestamp** (Optional but recommended)
   - Source: `@timestamp` or `request_body.timestamp`
   - When: When user request was received

## Migration Notes

### For Existing Deployments

If you have an existing schema, you'll need to run ALTER TABLE statements:

```sql
-- Add latency timestamps to usage_metrics
ALTER TABLE usage_metrics 
ADD COLUMN request_timestamp TIMESTAMP ENCODE delta32k,
ADD COLUMN response_timestamp TIMESTAMP ENCODE delta32k;

-- Add request timestamp to chat_sessions
ALTER TABLE chat_sessions 
ADD COLUMN request_timestamp TIMESTAMP ENCODE delta32k;

-- Update materialized views (drop and recreate)
DROP MATERIALIZED VIEW IF EXISTS mv_cost_analytics;
-- Then run the new CREATE MATERIALIZED VIEW statements

DROP MATERIALIZED VIEW IF EXISTS mv_user_usage_summary;
-- Then run the new CREATE MATERIALIZED VIEW statements

-- Create new materialized view
CREATE MATERIALIZED VIEW mv_latency_analytics ...;

-- Update helper views
-- Run new CREATE OR REPLACE VIEW statements
```

### Backfilling Data

For existing data, you may need to backfill timestamps if available in your source data:

```sql
-- Example: Backfill from event_timestamp (approximate)
UPDATE usage_metrics 
SET request_timestamp = event_timestamp - INTERVAL '1 second',
    response_timestamp = event_timestamp
WHERE request_timestamp IS NULL 
    AND response_timestamp IS NULL;
```

**Note**: Backfilled timestamps will be approximate. For accurate latency analysis, ensure ETL populates timestamps going forward.

## Performance Impact

### Storage
- Minimal: 2 TIMESTAMP fields per row in `usage_metrics` (~16 bytes per row)
- 1 TIMESTAMP field per row in `chat_sessions` (~8 bytes per row)

### Query Performance
- ✅ Improved: Calculated latency from timestamps is more efficient than complex JOINs
- ✅ Improved: Materialized views pre-calculate latency metrics
- ✅ Improved: Sort keys remain optimized

## Next Steps

1. ✅ **Schema Updated** - All base tables and views updated
2. ⏭️ **Deploy Changes** - Run ALTER TABLE statements if needed
3. ⏭️ **Update ETL** - Ensure ETL populates new timestamp fields
4. ⏭️ **Create Materialized Views** - Run new CREATE MATERIALIZED VIEW statements
5. ⏭️ **Test Queries** - Validate latency analysis queries work correctly
6. ⏭️ **Monitor Performance** - Ensure materialized view refreshes complete successfully

## Summary

This refactoring adds comprehensive latency analysis capabilities while maintaining schema efficiency. The new timestamp fields enable:
- Accurate latency measurement
- Time-of-day performance analysis
- Model and tool performance comparison
- Cost-latency correlation
- User experience impact analysis
- Anomaly detection

All changes follow Redshift best practices with proper encoding, sort keys, and distribution keys maintained.

