# Schema Changes Summary

## Tables Removed

The following tables have been removed from the schema:

1. **`browser_history`** - Removed (not needed for analytics)
2. **`search_results`** - Removed (search result count stored in `web_searches.result_count`)

---

## Impact Analysis

### Removed Tables

#### 1. browser_history
- **Previous Purpose**: Store browser history entries from `request_body.browser_history`
- **Removed Because**: Not needed for analytics
- **Impact**: 
  - Materialized view `mv_browser_history_analytics` removed
  - Helper view `v_extracted_domains` updated (removed browser_history reference)

#### 2. search_results
- **Previous Purpose**: Store individual search result details (title, URL, domain) for each search
- **Removed Because**: Not needed for analytics - only count is required
- **Impact**:
  - Helper view `v_search_operations` updated to use `web_searches.result_count` directly
  - Helper view `v_extracted_domains` updated (removed search_results reference)
  - `web_searches.result_count` already exists and stores the count (no JOIN needed)

---

## Updated Components

### Materialized Views
- ✅ **Removed**: `mv_browser_history_analytics` (was using `browser_history` table)

### Helper Views
- ✅ **Updated**: `v_extracted_domains` - Now only extracts domains from `web_automations.action_url`
- ✅ **Updated**: `v_search_operations` - Now uses `web_searches.result_count` directly instead of COUNT from `search_results`

### ER Diagram
- ✅ **Updated**: Removed `browser_history` and `search_results` entities and relationships

---

## Current Schema (After Changes)

### Core Tables (7 tables):
1. `chat_sessions` - Session metadata
2. `responses` - AI response content and metadata
3. `tool_usage` - Source table for intent classification
4. `web_searches` - Web search operations (includes `result_count`)
5. `browser_automations` - Browser automation actions
6. `web_automations` - Web automation actions
7. `usage_metrics` - Token usage and cost metrics

### Lookup Tables (1 table):
8. `domain_classifications` - Domain categorization reference

**Total: 8 tables** (down from 10)

---

## ETL Changes Required

### No Changes Needed for:
- ✅ `web_searches.result_count` - Already populated in ETL (count stored directly)
- ✅ Intent classifier workflow - No changes

### Removed from ETL:
- ❌ `browser_history` table inserts - No longer needed
- ❌ `search_results` table inserts - No longer needed

---

## Query Impact

### Queries Still Working:
- ✅ Search statistics: Use `mv_web_search_statistics` (uses `web_searches.result_count`)
- ✅ Domain analytics: Use `mv_domain_usage_stats` (uses `web_automations`)
- ✅ Browser automation analytics: Use `mv_browser_automation_details`

### Queries Removed:
- ❌ Browser history analytics: `mv_browser_history_analytics` (removed)
- ❌ Search result details: Individual result queries from `search_results` (removed)

### Alternative Approaches:
- **Search result count**: Available in `web_searches.result_count` (aggregated)
- **Domain extraction**: Use `v_extracted_domains` from `web_automations` only

---

## Migration Notes

If you have existing data:

1. **No migration needed** if you haven't deployed yet
2. **If already deployed**:
   ```sql
   -- Drop materialized view first
   DROP MATERIALIZED VIEW IF EXISTS mv_browser_history_analytics;
   
   -- Drop tables (after confirming no dependencies)
   DROP TABLE IF EXISTS browser_history;
   DROP TABLE IF EXISTS search_results;
   
   -- Update helper views will be handled by running 03_helper_views.sql
   ```

---

## Benefits of Removal

1. **Simplified Schema**: Fewer tables to maintain (8 vs 10)
2. **Reduced Storage**: No need to store detailed search results or browser history
3. **Faster ETL**: Less data to process and insert
4. **Easier Queries**: Direct use of aggregated `result_count` instead of JOINs
5. **Focused Analytics**: Only essential data for analytics goals retained

---

## Verification

To verify the schema changes:

```sql
-- Check tables exist (should return 8)
SELECT COUNT(*) FROM pg_tables 
WHERE schemaname = 'public' 
  AND tablename IN (
    'chat_sessions', 'responses', 'tool_usage', 
    'web_searches', 'browser_automations', 
    'web_automations', 'usage_metrics', 
    'domain_classifications'
  );

-- Verify removed tables don't exist
SELECT tablename FROM pg_tables 
WHERE schemaname = 'public' 
  AND tablename IN ('browser_history', 'search_results');
-- Should return 0 rows

-- Verify materialized views (should return 7, not 8)
SELECT COUNT(*) FROM pg_matviews 
WHERE matviewname LIKE 'mv_%';

-- Check result_count is populated in web_searches
SELECT 
    COUNT(*) AS total_searches,
    COUNT(result_count) AS with_result_count,
    AVG(result_count) AS avg_result_count
FROM web_searches
WHERE event_date >= CURRENT_DATE - 7;
```

---

## Summary

✅ **Removed**: `browser_history`, `search_results` tables  
✅ **Removed**: `mv_browser_history_analytics` materialized view  
✅ **Updated**: Helper views to remove references  
✅ **No Breaking Changes**: All analytics goals still achievable  
✅ **Simplified**: Schema is now more focused on essential analytics data  

The schema is now streamlined while maintaining all core analytics capabilities.

