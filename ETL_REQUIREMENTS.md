# ETL Requirements for Optimized Schema

## Critical ETL Population Requirements

The optimized schema requires specific columns to be populated during ETL to achieve optimal performance. **These are mandatory for the materialized views to work efficiently.**

## Important: Schema Normalization

**Best Practice Applied**: Response-level fields (`response_body.*`) are stored in `responses` table, not `chat_sessions`.
- ✅ `chat_sessions` = Session-level data (top-level, request_body)
- ✅ `responses` = Response-level data (response_body.*)
- This follows normalization best practices and improves query performance

---

## 1. event_date Column (REQUIRED)

### Tables Requiring event_date (REFACTORED - All Time-Series Tables):
- `chat_sessions` ⭐ NEW
- `responses` ⭐ NEW
- `tool_usage`
- `web_searches`
- `web_automations`
- `browser_automations` ⭐ NEW
- `usage_metrics`

**Note**: After refactoring, ALL tables with `event_timestamp` now require `event_date` for optimal sort key performance.

### ETL Implementation:
```sql
-- For each row being inserted, populate:
event_date = DATE(event_timestamp)
```

### Example (Python/Pseudocode):
```python
import datetime

def populate_event_date(row):
    if row['event_timestamp']:
        row['event_date'] = row['event_timestamp'].date()
    return row
```

### Why Critical:
- Allows sort key usage on date columns
- Eliminates DATE() function in GROUP BY (20-30% performance improvement)
- Enables efficient date-range queries

---

## 1b. Latency Timestamps (REQUIRED for usage_metrics)

### Tables Requiring Latency Timestamps:
- `usage_metrics`: `request_timestamp`, `response_timestamp` ⭐ NEW
- `chat_sessions`: `request_timestamp` ⭐ NEW (optional but recommended)

### ETL Implementation for usage_metrics:
```python
def populate_latency_timestamps(row, message_data):
    """
    Extract request and response timestamps for latency analysis.
    
    Sources:
    - request_timestamp: From request_body timestamp, @timestamp, or system log when request sent
    - response_timestamp: From response_body.created, response_body.timestamp, or system log when response received
    """
    # Option 1: From request_body
    request_body = message_data.get('request_body', {})
    if 'timestamp' in request_body:
        row['request_timestamp'] = convert_to_timestamp(request_body['timestamp'])
    elif '@timestamp' in message_data:
        row['request_timestamp'] = convert_to_timestamp(message_data['@timestamp'])
    
    # Option 2: From response_body
    response_body = message_data.get('response_body', {})
    if 'created' in response_body:
        row['response_timestamp'] = convert_to_timestamp(response_body['created'])
    elif 'timestamp' in response_body:
        row['response_timestamp'] = convert_to_timestamp(response_body['timestamp'])
    
    # Option 3: From system logs (if available)
    # row['request_timestamp'] = system_log.get_request_time(session_id)
    # row['response_timestamp'] = system_log.get_response_time(session_id)
    
    return row

def convert_to_timestamp(ts):
    """Convert various timestamp formats to TIMESTAMP."""
    import datetime
    if isinstance(ts, (int, float)):
        # Unix timestamp
        return datetime.datetime.fromtimestamp(ts)
    elif isinstance(ts, str):
        # ISO format or other string format
        # Parse based on your format
        return datetime.datetime.fromisoformat(ts.replace('Z', '+00:00'))
    return ts
```

### ETL Implementation for chat_sessions:
```python
def populate_session_request_timestamp(row, message_data):
    """
    Extract request timestamp for session-level latency tracking.
    """
    # Primary: @timestamp (when message was received)
    if '@timestamp' in message_data:
        row['request_timestamp'] = convert_to_timestamp(message_data['@timestamp'])
    # Fallback: request_body timestamp
    elif 'request_body' in message_data and 'timestamp' in message_data['request_body']:
        row['request_timestamp'] = convert_to_timestamp(message_data['request_body']['timestamp'])
    
    return row
```

### Why Critical:
- Enables accurate latency calculation from timestamps (more reliable than pre-calculated `latency_ms`)
- Supports time-of-day performance analysis
- Enables correlation between latency and costs/tokens
- Allows validation of reported latency against calculated latency
- Supports anomaly detection for latency spikes

### Latency Calculation:
```sql
-- Calculate latency from timestamps (ETL can validate latency_ms against this)
calculated_latency_ms = EXTRACT(EPOCH FROM (response_timestamp - request_timestamp)) * 1000
```

---

## 2. domain_category Column (CRITICAL for web_automations)

### Table: `web_automations`

### IMPORTANT: Domain Classification Method
**Domain classification is based on user query analysis**, NOT URL lookup. The intent classifier analyzes the `user_query` from `request_body` to determine the domain category.

### ETL Implementation:
```python
# STEP 1: Extract user query from request_body
def extract_user_query(message_data):
    """
    Extract user query from request_body.
    Try multiple fields as query may be in different locations.
    """
    request_body = message_data.get('request_body', {})
    
    user_query = (request_body.get('query') or 
                 request_body.get('message') or 
                 request_body.get('content') or
                 request_body.get('user_input') or
                 request_body.get('prompt'))
    
    return user_query

# STEP 2: Pass user query to intent classifier for domain classification
def populate_domain_category(row, user_query):
    """
    Get domain category from intent classifier based on user query analysis.
    """
    # Intent classifier analyzes user query
    classification = intent_classifier.classify_domain_from_query(
        user_query=user_query,
        session_id=row['session_id']
    )
    
    # Result from intent classifier:
    # {
    #     'domain_category': 'Shopping',  # Shopping, Booking, Entertainment, Work, Education, Finance
    #     'intent_type': 'Transactional',  # Transactional, Informational, Social, Entertainment, Productivity
    #     'subcategory': 'E-commerce',
    #     'confidence': 0.92
    # }
    
    row['domain_category'] = classification['domain_category']
    row['classification_confidence'] = classification['confidence']
    
    # Extract domain from URL separately (for domain_name field)
    row['domain_name'] = extract_domain_from_url(row['action_url'])
    
    return row

def extract_domain_from_url(url):
    """
    Extract domain from URL (separate from domain classification).
    Example: https://www.kurly.com/search?q=cheese -> kurly.com
    """
    if not url:
        return None
    
    import re
    match = re.search(r'https?://(?:www\.)?([^/]+)', url)
    if match:
        domain = match.group(1).lower()
        domain = domain.split(':')[0]  # Remove port if present
        return domain
    return None
```

### Complete Workflow:
```python
def process_web_automation(message_data):
    """
    Process web automation with domain classification.
    """
    session_id = message_data['_id']['$oid']
    
    # Step 1: Extract user query
    user_query = extract_user_query(message_data)
    
    # Step 2: Get domain classification from intent classifier
    classification = intent_classifier.classify_domain_from_query(
        user_query=user_query,
        session_id=session_id
    )
    
    # Step 3: Extract domain from URL (extract temporarily for domain_name, don't store URL)
    action_url = extract_action_url(message_data)  # Temporary variable - extract domain_name only
    domain_name = extract_domain_from_url(action_url)
    
    # Step 4: Prepare row (action_url NOT stored - only domain_name is kept)
    row = {
        'session_id': session_id,
        'tool_usage_id': tool_usage_id,
        # action_url removed - only domain_name stored for storage efficiency
        'domain_category': classification['domain_category'],  # From intent classifier (user query)
        'domain_name': domain_name,  # From URL extraction (ONLY store this, not full URL)
        'classification_confidence': classification['confidence'],
        # ... other fields
    }
    
    # Step 5: Insert
    insert_into_web_automations(row)
```

### Why Critical:
- Eliminates COALESCE in materialized view GROUP BY
- Enables optimal sort key usage
- 20-30% faster materialized view refresh
- **More accurate**: Based on user intent, not just domain name

### Intent Classifier Requirements:
- Must analyze user query from `request_body`
- Must return `domain_category`, `intent_type`, `confidence`
- Should handle confidence thresholds (recommended: 0.7 minimum)

---

## 3. Aggregations in Materialized Views (NOT in Base Tables)

### Important Principle:
**Counts, sums, averages, and other aggregations should be calculated in materialized views, NOT stored in base tables.**

### Base Tables Should Contain:
- ✅ Raw fact data (event_timestamp, num_results, etc.)
- ✅ Derived columns for performance (event_date, domain_category)
- ❌ NO pre-calculated aggregations (COUNT, SUM, AVG, etc.)

### Materialized Views Handle:
- ✅ COUNT(*) aggregations
- ✅ SUM() aggregations
- ✅ AVG() aggregations
- ✅ COUNT(DISTINCT) aggregations

### Example:
```sql
-- ❌ WRONG: Storing aggregation in base table
CREATE TABLE web_searches (
    ...
    result_count INTEGER  -- Aggregation - should NOT be here
);

-- ✅ CORRECT: Calculate in materialized view
CREATE MATERIALIZED VIEW mv_web_search_statistics AS
SELECT 
    event_date,
    search_type,
    COUNT(*) AS search_count,  -- Aggregation in MV
    SUM(num_results) AS total_results  -- Aggregation in MV
FROM web_searches
GROUP BY event_date, search_type;
```

---

## 4. domain_name Extraction (REQUIRED)

### Tables: `web_automations`

### ETL Implementation:
```python
import re

def extract_domain_name(url):
    """
    Extract domain name from URL.
    
    Examples:
    - https://www.kurly.com/search?q=cheese -> kurly.com
    - https://devtalk.kakao.com/topic/123 -> devtalk.kakao.com
    - http://www.amazon.com/product -> amazon.com
    """
    if not url:
        return None
    
    # Pattern: http(s)://(optional www.)domain(.tld)/...
    pattern = r'https?://(?:www\.)?([^/]+)'
    match = re.search(pattern, url, re.IGNORECASE)
    
    if match:
        domain = match.group(1).lower()
        # Remove port if present
        domain = domain.split(':')[0]
        return domain
    
    return None

# Usage:
row['domain_name'] = extract_domain_name(row['action_url'])
```

### SQL Pattern (if doing in Redshift):
```sql
-- Can be done with REGEXP, but better to do in ETL
SELECT REGEXP_REPLACE(
    REGEXP_SUBSTR(url, 'https?://([^/]+)'),
    'https?://', ''
) AS domain_name;
```

---

---

## Note: Removed Tables

The following tables have been removed from the schema:
- `browser_history` - Not needed for analytics
- `search_results` - Search result count stored in `web_searches.result_count`

---

## Complete ETL Workflow Example

### For web_automations table:

```python
def process_web_automation(message_data):
    """
    Process web automation data from topic message
    """
    # Extract data from message
    action_url = message_data['agent_progress']['url']  # Temporary - extract domain_name only
    action_type = message_data['agent_progress']['action']
    event_timestamp = message_data['@timestamp']
    
    # Extract domain (action_url used temporarily, not stored)
    domain_name = extract_domain_from_url(action_url)
    
    # Get domain category from intent classifier (user query analysis)
    user_query = extract_user_query(message_data)
    domain_category = intent_classifier.classify_domain_from_query(user_query)['domain_category']
    
    # Populate row (action_url NOT stored - removed for storage efficiency)
    row = {
        'session_id': message_data['_id']['$oid'],
        'thread_id': message_data['thread_id'],
        'event_timestamp': event_timestamp,
        'event_date': datetime.fromtimestamp(event_timestamp).date(),  # CRITICAL
        'action_type': action_type,  # REQUIRED - what action was performed
        # action_url removed - only domain_name stored for storage efficiency
        'domain_category': domain_category,  # CRITICAL - from intent classifier (user query)
        'domain_name': domain_name,  # CRITICAL - extracted (ONLY store this, not full URL)
        # ... other fields ...
    }
    
    # Insert
    insert_into_web_automations(row)
```

### For web_searches table:

```python
def process_web_search(message_data):
    """
    Process web search data from topic message.
    AGGREGATIONS: Counts will be calculated in materialized views, not stored here.
    """
    event_timestamp = message_data['@timestamp']
    
    # Extract num_results from search response (raw data, not aggregation)
    num_results = message_data.get('response_body', {}).get('search_results', {}).get('num_results') or \
                  len(message_data.get('response_body', {}).get('search_results', []))
    
    # Populate row (NO aggregations - use materialized views for counts)
    row = {
        'session_id': message_data['_id']['$oid'],
        'thread_id': message_data['thread_id'],
        'event_timestamp': event_timestamp,
        'event_date': datetime.fromtimestamp(event_timestamp).date(),  # CRITICAL
        'search_type': message_data.get('web_search_options', {}).get('search_type'),
        'search_keywords': json.dumps(message_data.get('search_keywords', [])),
        'num_results': num_results,  # Raw data from search response
        # ... other fields ...
    }
    
    # Insert web_searches (aggregations handled by materialized views)
    insert_into_web_searches(row)
```

---

## Validation Queries

After ETL implementation, run these to verify:

### Check event_date population:
```sql
SELECT 
    COUNT(*) AS total_rows,
    COUNT(event_date) AS populated_event_date,
    COUNT(*) - COUNT(event_date) AS missing_event_date
FROM tool_usage;

-- Should show 0 missing_event_date
```

### Check domain_category population:
```sql
SELECT 
    COUNT(*) AS total_rows,
    COUNT(domain_category) AS populated_domain_category,
    SUM(CASE WHEN domain_category = 'Unknown' THEN 1 ELSE 0 END) AS unknown_count
FROM web_automations;

-- Review unknown_count - may indicate missing domain_classifications entries
```

### Check num_results (raw data, not aggregation):
```sql
-- Verify num_results is populated (raw data from search response)
SELECT 
    COUNT(*) AS total_searches,
    COUNT(num_results) AS with_num_results,
    COUNT(*) - COUNT(num_results) AS missing_num_results
FROM web_searches
WHERE event_date >= CURRENT_DATE - 7;

-- Should show 0 missing_num_results
-- Note: Aggregations (COUNT, SUM, AVG) should be queried from materialized views
```

---

## Performance Impact

### Without Optimizations:
- Materialized view refresh: ~5-10 minutes
- Date-range queries: Full table scan
- Domain analytics: COALESCE overhead

### With Optimizations:
- Materialized view refresh: ~3-7 minutes (30-40% faster)
- Date-range queries: Uses sort key (10-100x faster)
- Domain analytics: Direct sort key usage (2-5x faster)

---

## Migration Strategy

If you have existing data:

### Step 1: Add columns (if not already added)
```sql
ALTER TABLE tool_usage ADD COLUMN event_date DATE;
ALTER TABLE web_searches ADD COLUMN event_date DATE;
-- Note: NO aggregation columns (result_count, etc.) - aggregations in materialized views
-- etc.
```

### Step 2: Backfill data
```sql
-- Backfill event_date
UPDATE tool_usage 
SET event_date = DATE(event_timestamp)
WHERE event_date IS NULL;

-- Backfill domain_category (if needed)
UPDATE web_automations wa
SET domain_category = (
    SELECT dc.domain_category
    FROM domain_classifications dc
    WHERE dc.domain_name = wa.domain_name
        AND dc.is_active = TRUE
    LIMIT 1
)
WHERE domain_category IS NULL;
```

### Step 3: Update materialized views
```sql
REFRESH MATERIALIZED VIEW mv_basic_statistics;
REFRESH MATERIALIZED VIEW mv_domain_usage_stats;
REFRESH MATERIALIZED VIEW mv_web_search_statistics;
-- etc.
```

---

## Checklist for ETL Team

- [ ] Extract `event_date = DATE(event_timestamp)` for all tables
- [ ] Extract `user_query` from `request_body` for domain classification
- [ ] Extract `domain_name` from URLs using regex
- [ ] Pass `user_query` to intent classifier for `domain_category` classification
- [ ] **DO NOT** calculate aggregations (COUNT, SUM, etc.) - these are done in materialized views
- [ ] Store raw data only (num_results is OK, result_count is NOT)
- [ ] Validate all required columns are populated
- [ ] Run validation queries after initial load
- [ ] Monitor materialized view refresh times

---

## Support

If you encounter issues:
1. Check validation queries above
2. Review materialized view refresh logs
3. Verify domain_classifications table has needed entries
4. Check for NULL values in critical columns

