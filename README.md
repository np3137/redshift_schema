# Redshift Schema Design for Chat Analytics

## Overview

This schema design captures chat interaction data from topic messages and organizes it for analytics. The design supports all stated goals including basic statistics, detailed tool usage, usage metrics, and future enhancements for feedback and personalization.

## File Structure

1. **01_base_tables.sql** - Core normalized tables
2. **02_materialized_views.sql** - Pre-aggregated views (BATCH mode - AUTO REFRESH NO)
3. **02_materialized_views_optimized.sql** - Optimized versions (see efficiency guide)
4. **03_helper_views.sql** - Supporting views for data transformation
5. **04_query_examples.sql** - Example queries for common use cases
6. **05_phase2_tables.sql** - Future tables for Phase 2 features
7. **06_batch_refresh_scripts.sql** - Automated refresh procedures for batch analytics
8. **BATCH_ANALYTICS_GUIDE.md** - Complete guide for non-real-time batch analytics
9. **BATCH_ANALYTICS_SUMMARY.md** - Quick reference for batch configuration
10. **REDSHIFT_EFFICIENCY_GUIDE.md** - Comprehensive efficiency analysis
11. **QUERY_PERFORMANCE_CHECKLIST.md** - Quick reference for query optimization
12. **EFFICIENCY_SUMMARY.md** - Executive summary and recommendations
13. **SCHEMA_UPDATE_RESPONSE_ID.md** - Response table normalization details
14. **SCHEMA_NORMALIZATION_UPDATE.md** - Normalization changes explanation
15. **TASK_COMPLETION_TRACKING.md** - Task completion analysis guide
16. **QUERYING_RESPONSE_STATUS.md** - How to query normalized response fields
17. **TABLE_REQUIREMENTS_AND_PURPOSE.md** - Complete table requirements guide
18. **REDSHIFT_SCHEMA_BEST_PRACTICES.md** - Best practices guide

## Key Design Principles

### Distribution Keys
- Primary distribution key: `session_id` (high cardinality, used in joins)
- Secondary: `user_id` for user-centric tables (Phase 2)

### Sort Keys
- Composite sort keys with timestamp first for time-series queries
- Include frequently filtered columns

### Materialized Views
- Use `AUTO REFRESH NO` for batch/non-real-time analytics (manual refresh)
- `BACKUP NO` since they can be regenerated
- Refresh during scheduled ETL windows (recommended: daily at 2 AM)
- Optimized for read-heavy analytics queries

## Goals Mapping

### Goal 1: Basic Statistical Data
- **Tables**: `tool_usage`, `web_searches`, `browser_automations`, `web_automations`
- **View**: `mv_basic_statistics`
- **Tracks**: Search, Browser Automation, Web Automation counts

### Goal 2: Detailed Tool Usage
- **Tables**: `browser_automations`, `web_automations`, `domain_classifications`
- **Views**: `mv_domain_usage_stats`, `mv_browser_automation_details`
- **Tracks**: 
  - Browser Automation: What users are doing (searching history, grouping tabs)
  - Web Automation: Specific actions on domains (shopping, booking, etc.)
  - Domain categorization: Shopping, Booking, Entertainment, Work, Education, Finance

### Goal 3: Usage Metrics
- **Tables**: `usage_metrics`
- **Views**: `mv_user_usage_summary`, `mv_cost_analytics`
- **Tracks**: Per-user usage counts, total usage across all users, token usage, costs

### Goal 4: System Quality Analysis (Phase 2)
- **Tables**: `user_feedback`
- **View**: `mv_feedback_analytics`
- **Tracks**: Likes/dislikes for quality analysis

### Goal 5: Test Data Utilization (Phase 2)
- **Tables**: `test_data_collection`
- **Tracks**: Liked responses collected for training data

### Goal 6: Long-term Memory (Phase 2)
- **Tables**: `user_profiles`, `session_context`, `bookmarks`, `tab_groups`, `research_sessions`, `interruptions`
- **View**: `mv_user_personalization_stats`
- **Tracks**: AI Agent personalization, research, interruptions, history, bookmarks, tab grouping

## Topic Message Extraction

The schema extracts the following from topic messages:

### From Top Level:
- `_id` → `session_id`
- `room_id` → `chat_sessions.room_id`
- `thread_id` → Used across all tables
- `@timestamp` → `event_timestamp`
- `timestamp.$date` → `created_timestamp`

### From request_body:
- `browser_history[]` → `browser_history` table
- `web_search_options.search_type` → `web_searches.search_type`

### From response_body:
- `search_results[]` → `search_results` table
- `usage.*` → `usage_metrics` table
- `model`, `status`, `type`, `object` → `responses` table (normalized)
- `choices[].message.reasoning_steps[]` → `tool_usage`, `web_searches`, `browser_automations`, `web_automations`

### Reasoning Steps Types:
1. **web_search** → `tool_usage` + `web_searches` + `search_results`
2. **browser_tool_execution** → `tool_usage` + `browser_automations`
3. **agent_progress** (with `step_type: ENTROPY_REQUEST`) → `tool_usage` + `web_automations`

## Domain Classification

The `domain_classifications` table provides a reference for categorizing URLs into:
- **Categories**: Shopping, Booking, Entertainment, Work, Education, Finance
- **Intent Types**: Transactional, Informational, Social, Entertainment, Productivity

URLs are automatically matched during ETL, with fallback to 'Unknown' if no match is found.

## Usage Examples

See `04_query_examples.sql` for:
- Basic statistics queries
- Domain analytics
- Usage metrics
- Cost analytics
- Complex user journey analysis

## ETL Considerations

1. **Session ID Generation**: Use `_id.$oid` or generate UUID from message
2. **Timestamp Conversion**: Convert Unix timestamps (`last_visit_ts`) to TIMESTAMP
3. **Domain Extraction**: Extract domain from URLs using regex
4. **Domain Matching**: Join against `domain_classifications` table
5. **JSON Parsing**: Handle nested arrays in `reasoning_steps`
6. **Deduplication**: Use session_id + timestamp combinations
7. **Response Fields**: Store all `response_body.*` fields in `responses` table (normalized)
8. **Event Date Population**: **CRITICAL** - Populate `event_date = DATE(event_timestamp)` for performance
9. **Batch Refresh**: Schedule materialized view refresh during off-peak hours (2 AM)

## Performance Optimization

1. Use materialized views for frequently queried aggregations
2. Composite sort keys for time-series queries
3. Distribution keys matching join patterns
4. Automatic encoding to optimize storage

## Next Steps

1. ✅ **Schema Design** - Complete
2. ⏭️ **Deploy Tables** - Run `01_base_tables.sql`
3. ⏭️ **Populate Domain Classifications** - Insert known domains
4. ⏭️ **Set Up ETL** - Build pipeline for topic messages
5. ⏭️ **Create Materialized Views** - Run `02_materialized_views.sql`
6. ⏭️ **Set Up Batch Refresh** - Configure refresh schedule (see `BATCH_ANALYTICS_GUIDE.md`)
7. ⏭️ **Deploy Refresh Scripts** - Run `06_batch_refresh_scripts.sql`
8. ⏭️ **Test Queries** - Use `04_query_examples.sql`
9. ⏭️ **Schedule Daily Refresh** - Set up cron/scheduler for 2 AM refresh
10. ⏭️ **Monitor Performance** - Adjust sort/distribution keys as needed

## Important: Batch Analytics Configuration

**All materialized views are configured for batch/non-real-time analytics**:
- ✅ `AUTO REFRESH NO` - Manual refresh required
- ✅ Refresh during scheduled ETL windows (recommended: daily 2 AM)
- ✅ Use `06_batch_refresh_scripts.sql` for automated refresh
- ✅ See `BATCH_ANALYTICS_GUIDE.md` for complete configuration guide

