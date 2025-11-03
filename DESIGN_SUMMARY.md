# Design Summary: Redshift Schema for Chat Analytics

## Executive Summary

This design provides a comprehensive Redshift schema to capture and analyze chat interaction data from topic messages. The schema supports all stated goals with normalized base tables, optimized materialized views, and extensibility for future features.

---

## 1. Redshift Schema Design Considerations

### Key Principles Applied

✅ **Distribution Keys**: `thread_id` used as DISTKEY across transactional tables for optimal join performance  
✅ **Sort Keys**: Composite keys with timestamp first for time-series queries  
✅ **Column Encoding**: `ENCODE AUTO` for automatic optimization  
✅ **Data Types**: Appropriate VARCHAR lengths, BIGINT for IDs, TIMESTAMP for dates  
✅ **Materialized Views**: `AUTO REFRESH YES` for automatic updates, `BACKUP NO` for storage efficiency

### Materialized View Strategy

- Pre-aggregate frequently queried metrics
- Simplify complex JOINs
- Auto-refresh on base table changes
- Optimized for read-heavy analytics workloads

---

## 2. High-Level Design (HLD)

### Architecture

```
Topic Message (JSON)
    ↓
ETL Pipeline
    ↓
Redshift Base Tables (Normalized)
    ↓
Materialized Views (Pre-aggregated)
    ↓
Analytics/Reporting
```

### Data Flow

1. **Extract**: Parse JSON topic messages
2. **Transform**: Normalize, extract domains, classify actions
3. **Load**: Insert into Redshift tables
4. **Materialize**: Create aggregated views

---

## 3. Goals Coverage

### ✅ Goal 1: Basic Statistical Data
**Implementation**: 
- Tables: `tool_usage`, `web_searches`, `browser_automations`, `web_automations`
- View: `mv_basic_statistics`
- Tracks: Search (`web_search`), Browser Automation (`browser_tool_execution`), Web Automation (`ENTROPY_REQUEST`)

### ✅ Goal 2: Detailed Tool Usage
**Implementation**:
- **Browser Automation**: `browser_automations` table + `mv_browser_automation_details`
- **Web Automation**: `web_automations` table + `mv_domain_usage_stats`
- **Domain Categories**: `domain_classifications` table with:
  - Shopping, Booking, Entertainment, Work, Education, Finance
  - Transactional, Informational, Social, Entertainment, Productivity

### ✅ Goal 3: Usage Metrics
**Implementation**:
- Per-user: `mv_user_usage_summary` (by thread_id)
- Total usage: Aggregated from `mv_user_usage_summary`
- Metrics: Token usage, cost, session counts

### ⏳ Goal 4: System Quality Analysis (Phase 2)
**Implementation**: `user_feedback` table + `mv_feedback_analytics`

### ⏳ Goal 5: Test Data Utilization (Phase 2)
**Implementation**: `test_data_collection` table for liked responses

### ⏳ Goal 6: Long-term Memory (Phase 2)
**Implementation**: 
- `user_profiles` - Personalization
- `session_context` - Context storage
- `bookmarks` - User bookmarks
- `tab_groups` - Tab grouping
- `research_sessions` - Research tracking
- `interruptions` - Interruption tracking

---

## 4. Topic Message Structure Mapping

### Extraction Points

| Topic Message Field | Target Table | Target Column |
|---------------------|--------------|---------------|
| `_id.$oid` | `chat_sessions` | `session_id` |
| `thread_id` | All tables | `thread_id` |
| `@timestamp` | All tables | `event_timestamp` |
| `timestamp.$date` | `chat_sessions` | `created_timestamp` |
| `request_body.browser_history[]` | `browser_history` | Various |
| `response_body.search_results[]` | `search_results` | Various |
| `response_body.usage.*` | `usage_metrics` | Various |
| `choices[].message.reasoning_steps[]` | `tool_usage` + specialized tables | Various |

### Reasoning Steps Mapping

| Step Type | Tables Populated |
|-----------|------------------|
| `web_search` | `tool_usage`, `web_searches`, `search_results` |
| `browser_tool_execution` | `tool_usage`, `browser_automations` |
| `agent_progress` (ENTROPY_REQUEST) | `tool_usage`, `web_automations` |

---

## 5. Table Schema Summary

### Core Tables (9)

1. **chat_sessions** - Main session/thread data
2. **tool_usage** - All tool call events
3. **web_searches** - Web search operations
4. **browser_automations** - Browser automation actions
5. **web_automations** - Web automation actions (ENTROPY_REQUEST)
6. **browser_history** - Browser history entries
7. **search_results** - Search result details
8. **usage_metrics** - Token usage, cost, latency
9. **domain_classifications** - Domain categorization reference

### Materialized Views (7)

1. **mv_basic_statistics** - Activity type counts
2. **mv_user_usage_summary** - Per-user metrics
3. **mv_domain_usage_stats** - Domain analytics
4. **mv_browser_automation_details** - Browser action details
5. **mv_cost_analytics** - Cost and token analytics
6. **mv_web_search_statistics** - Search analytics
7. **mv_browser_history_analytics** - History domain analytics

### Phase 2 Tables (7)

1. **user_feedback** - Likes/dislikes
2. **test_data_collection** - Training data
3. **user_profiles** - Personalization
4. **session_context** - Context storage
5. **bookmarks** - User bookmarks
6. **tab_groups** - Tab grouping
7. **research_sessions** - Research tracking
8. **interruptions** - Interruption tracking

---

## 6. Key Features

### Domain Classification

- Automatic domain extraction from URLs
- Categorization: Shopping, Booking, Entertainment, Work, Education, Finance
- Intent classification: Transactional, Informational, Social, etc.
- Extensible via `domain_classifications` table

### Query Optimization

- Materialized views for common aggregations
- Composite sort keys for time-series queries
- Distribution keys matching join patterns
- Helper views for data transformation

### Data Quality

- NOT NULL constraints on required fields
- Automatic timestamp defaults
- Domain classification fallback to 'Unknown'
- JSON fields for flexible metadata

---

## 7. Example Use Cases

### Use Case 1: Track Search Usage
```sql
SELECT * FROM mv_basic_statistics 
WHERE tool_type = 'web_search';
```

### Use Case 2: Shopping Domain Analytics
```sql
SELECT * FROM mv_domain_usage_stats 
WHERE domain_category = 'Shopping';
```

### Use Case 3: Per-User Usage
```sql
SELECT thread_id, SUM(usage_count) AS total_usage
FROM mv_user_usage_summary
GROUP BY thread_id;
```

### Use Case 4: Cost Analysis
```sql
SELECT SUM(total_cost) AS total_cost
FROM mv_cost_analytics
WHERE event_date >= CURRENT_DATE - 30;
```

---

## 8. ETL Requirements

### Extraction
- Parse JSON topic messages
- Handle nested arrays (reasoning_steps, browser_history, search_results)
- Extract timestamps (Unix and ISO format)

### Transformation
- Generate session_id from `_id.$oid`
- Extract domain names from URLs using regex
- Match domains to `domain_classifications` table
- Classify actions (click, search, add_to_cart, etc.)
- Normalize data structure

### Loading
- Insert into base tables with proper distribution
- Handle duplicates (session_id + timestamp)
- Maintain referential integrity in application logic

---

## 9. Next Steps

1. ✅ **Schema Design** - Complete
2. ⏭️ **Deploy Tables** - Run `01_base_tables.sql`
3. ⏭️ **Populate Domain Classifications** - Insert known domains
4. ⏭️ **Set Up ETL** - Build pipeline for topic messages
5. ⏭️ **Create Materialized Views** - Run `02_materialized_views.sql`
6. ⏭️ **Test Queries** - Use `04_query_examples.sql`
7. ⏭️ **Monitor Performance** - Adjust sort/distribution keys as needed

---

## 10. File Structure

```
redshift_schemas/
├── README.md                    # Overview and documentation
├── DESIGN_SUMMARY.md            # This file
├── 01_base_tables.sql          # Core normalized tables
├── 02_materialized_views.sql   # Pre-aggregated views
├── 03_helper_views.sql         # Supporting views
├── 04_query_examples.sql       # Example queries
└── 05_phase2_tables.sql        # Future Phase 2 tables
```

---

## 11. Key Takeaways

✅ **Comprehensive**: Covers all stated goals with extensibility for Phase 2  
✅ **Optimized**: Proper distribution/sort keys and materialized views  
✅ **Normalized**: Clean data model with proper relationships  
✅ **Queryable**: Materialized views for fast analytics  
✅ **Maintainable**: Well-documented with examples and helper views

