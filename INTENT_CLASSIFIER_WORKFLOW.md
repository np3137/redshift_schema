# Intent Classifier Workflow Documentation

## Overview

Before creating tables in Redshift, an **Intent Classifier** performs two key functions:

1. **Tool Routing**: Determines whether records should be routed to `browser_automations` or `web_automations` tables based on `tool_type` and `step_type` fields from the `tool_usage` table.

2. **Domain Classification**: Analyzes the **user_query** from `request_body` to determine the domain category (Shopping, Booking, Entertainment, Work, Education, Finance) and intent type (Transactional, Informational, Social, Entertainment, Productivity).

The intent classifier processes the user query to understand the user's intent and assigns appropriate domain categories for analytics.

---

## Classification Logic

### Two-Stage Classification Process

#### Stage 1: Tool Routing Classification

The intent classifier uses the following logic to route records to specialized tables:

```
┌─────────────────────────────────────────────────────────────┐
│              INTENT CLASSIFIER DECISION TREE                 │
└─────────────────────────────────────────────────────────────┘

IF tool_type = 'web_search':
    └─> Route to: web_searches + search_results
    
ELSE IF tool_type = 'browser_tool_execution':
    └─> Route to: browser_automations
    
ELSE IF tool_type = 'agent_progress' AND step_type = 'ENTROPY_REQUEST':
    └─> Route to: web_automations
    
ELSE:
    └─> Keep in tool_usage only (no specialized table)
```

#### Stage 2: Domain Classification (Based on User Query)

The intent classifier analyzes the **user_query** from `request_body` to determine:

1. **Domain Category**: Shopping, Booking, Entertainment, Work, Education, Finance
2. **Intent Type**: Transactional, Informational, Social, Entertainment, Productivity
3. **Subcategory**: E-commerce, Travel, Media, Developer Tools, etc.

**Classification Process**:
```
User Query (from request_body)
    │
    ▼
Intent Classifier Analysis
    │
    ├─> Extracts intent/context
    ├─> Matches against query patterns
    ├─> Determines domain category
    └─> Assigns intent type
    │
    ▼
Populate domain_category in web_automations
```

### Classification Mapping

#### Tool Routing:
| tool_type | step_type | Classification Target | Destination Table |
|-----------|-----------|----------------------|-------------------|
| `web_search` | * | `web_search` | `web_searches` |
| `browser_tool_execution` | * | `browser_automation` | `browser_automations` |
| `agent_progress` | `ENTROPY_REQUEST` | `web_automation` | `web_automations` |
| `agent_progress` | `*` (other) | `none` | `tool_usage` only |
| * (other) | * | `none` | `tool_usage` only |

#### Domain Classification Examples:
| User Query Example | Domain Category | Intent Type | Subcategory |
|-------------------|----------------|-------------|-------------|
| "Buy groceries on kurly.com" | Shopping | Transactional | E-commerce |
| "Book a flight to Seoul" | Booking | Transactional | Travel |
| "Search for React documentation" | Work | Informational | Developer Tools |
| "Watch YouTube video" | Entertainment | Entertainment | Media |
| "Check my bank balance" | Finance | Informational | Banking |

---

## ETL Workflow

### Step 1: Extract User Query and Insert into chat_sessions

First, extract the user query from `request_body` and insert into `chat_sessions`:

```python
# Extract user query from request_body
user_query = message_data.get('request_body', {}).get('query') or \
             message_data.get('request_body', {}).get('message') or \
             message_data.get('request_body', {}).get('content')

# Insert into chat_sessions
chat_session_row = {
    'session_id': message_data['_id']['$oid'],
    'thread_id': message_data['thread_id'],
    'event_timestamp': parse_timestamp(message_data['@timestamp']),
    'event_date': parse_timestamp(message_data['@timestamp']).date(),
    'user_query': user_query,  # CRITICAL: For intent classifier
    # ... other fields
}
insert_into_chat_sessions(chat_session_row)
```

### Step 2: Insert into tool_usage (Source Table)

All tool usage events are inserted into `tool_usage` table:

```sql
INSERT INTO tool_usage (
    session_id,
    thread_id,
    event_timestamp,
    event_date,
    tool_type,
    step_type,
    classification_target  -- Initially NULL, populated by classifier
) VALUES (...);
```

### Step 3: Intent Classifier Processing (Two Stages)

#### Stage 3a: Tool Routing Classification

The intent classifier reads from `tool_usage` and determines routing:

```python
def classify_tool_routing(tool_usage_record):
    """
    Stage 1: Classify tool usage record and determine routing.
    
    Returns:
        classification_target: 'web_search', 'browser_automation', 'web_automation', or 'none'
        confidence: 0.00-1.00 (optional)
    """
    tool_type = tool_usage_record['tool_type']
    step_type = tool_usage_record.get('step_type')
    
    if tool_type == 'web_search':
        return 'web_search', 1.0
    
    elif tool_type == 'browser_tool_execution':
        return 'browser_automation', 1.0
    
    elif tool_type == 'agent_progress' and step_type == 'ENTROPY_REQUEST':
        return 'web_automation', 1.0
    
    else:
        return 'none', 0.0
```

#### Stage 3b: Domain Classification (Based on User Query)

The intent classifier analyzes the user query to determine domain category:

```python
def classify_domain_from_query(user_query, session_id):
    """
    Stage 2: Classify domain category based on user query analysis.
    
    Args:
        user_query: User query text from request_body
        session_id: Session ID to link classification
    
    Returns:
        domain_category: 'Shopping', 'Booking', 'Entertainment', 'Work', 'Education', 'Finance'
        intent_type: 'Transactional', 'Informational', 'Social', 'Entertainment', 'Productivity'
        subcategory: 'E-commerce', 'Travel', 'Media', etc.
        confidence: 0.00-1.00
    """
    # Intent classifier analyzes the query
    classification = intent_classifier.analyze_query(user_query)
    
    return {
        'domain_category': classification['domain_category'],
        'intent_type': classification['intent_type'],
        'subcategory': classification.get('subcategory', 'Unknown'),
        'confidence': classification['confidence']
    }
```

### Step 4: Update tool_usage with Classification

```sql
UPDATE tool_usage
SET classification_target = 'browser_automation',
    -- classification_confidence can be updated if available
WHERE tool_usage_id = :tool_usage_id;
```

### Step 5: Route to Specialized Tables with Domain Classification

Based on `classification_target`, insert into appropriate table:

#### Route to web_searches:

```sql
-- When classification_target = 'web_search'
INSERT INTO web_searches (
    tool_usage_id,
    session_id,
    thread_id,
    event_timestamp,
    event_date,
    search_type,
    search_keywords,
    num_results,
    result_count
) 
SELECT 
    tu.tool_usage_id,
    tu.session_id,
    tu.thread_id,
    tu.event_timestamp,
    tu.event_date,
    :search_type,
    :search_keywords,
    :num_results,
    :result_count
FROM tool_usage tu
WHERE tu.tool_usage_id = :tool_usage_id;
```

#### Route to browser_automations:

```sql
-- When classification_target = 'browser_automation'
INSERT INTO browser_automations (
    tool_usage_id,
    session_id,
    thread_id,
    event_timestamp,
    event_date,
    action_type,
    step_type,
    user_id,
    classification_confidence
)
SELECT 
    tu.tool_usage_id,
    tu.session_id,
    tu.thread_id,
    tu.event_timestamp,
    tu.event_date,
    :action_type,
    tu.step_type,
    :user_id,
    :confidence_score
FROM tool_usage tu
WHERE tu.tool_usage_id = :tool_usage_id;
```

#### Route to web_automations:

```python
# When classification_target = 'web_automation'
# STEP 1: Get user query from chat_sessions
user_query = get_user_query_from_chat_sessions(session_id)

# STEP 2: Intent classifier analyzes user query for domain classification
domain_classification = classify_domain_from_query(user_query, session_id)

# STEP 3: Extract domain from URL (for domain_name field)
domain_name = extract_domain_from_url(action_url)

# STEP 4: Insert into web_automations with classified domain_category
INSERT INTO web_automations (
    tool_usage_id,
    session_id,
    thread_id,
    event_timestamp,
    event_date,
    action_type,
    action_url,
    domain_category,  -- From intent classifier (user query analysis)
    domain_name,       -- Extracted from URL
    task_status,
    task_completed,
    classification_confidence  -- Confidence from intent classifier
)
SELECT 
    tu.tool_usage_id,
    tu.session_id,
    tu.thread_id,
    tu.event_timestamp,
    tu.event_date,
    :action_type,
    :action_url,
    :domain_category,   -- From intent classifier (NOT from domain_classifications table lookup)
    :domain_name,      -- Extracted from action_url
    :task_status,
    :task_completed,
    :classification_confidence  -- From intent classifier
FROM tool_usage tu
WHERE tu.tool_usage_id = :tool_usage_id;
```

---

## Complete ETL Pipeline Example

```python
def process_tool_usage_message(message_data):
    """
    Complete ETL pipeline with intent classification (tool routing + domain classification).
    """
    session_id = message_data['_id']['$oid']
    
    # Step 1: Extract user query and insert into chat_sessions
    user_query = extract_user_query(message_data)  # From request_body
    insert_into_chat_sessions({
        'session_id': session_id,
        'thread_id': message_data['thread_id'],
        'event_timestamp': parse_timestamp(message_data['@timestamp']),
        'event_date': parse_timestamp(message_data['@timestamp']).date(),
        'user_query': user_query,  # CRITICAL for domain classification
        # ... other fields
    })
    
    # Step 2: Extract and insert into tool_usage
    tool_usage_row = {
        'session_id': session_id,
        'thread_id': message_data['thread_id'],
        'event_timestamp': parse_timestamp(message_data['@timestamp']),
        'event_date': parse_timestamp(message_data['@timestamp']).date(),
        'tool_type': extract_tool_type(message_data),
        'step_type': extract_step_type(message_data),
        'classification_target': None  # To be set by classifier
    }
    
    tool_usage_id = insert_into_tool_usage(tool_usage_row)
    
    # Step 3: Stage 1 - Tool Routing Classification
    routing_result = intent_classifier.classify_tool_routing(
        tool_type=tool_usage_row['tool_type'],
        step_type=tool_usage_row['step_type']
    )
    
    classification_target = routing_result['target']
    routing_confidence = routing_result.get('confidence', 1.0)
    
    # Step 4: Update tool_usage with routing classification
    update_tool_usage_classification(
        tool_usage_id,
        classification_target,
        routing_confidence
    )
    
    # Step 5: Stage 2 - Domain Classification (for web_automations)
    if classification_target == 'web_automation':
        # Analyze user query for domain classification
        domain_classification = intent_classifier.classify_domain_from_query(
            user_query=user_query,
            session_id=session_id
        )
        
        # Step 6: Route to specialized table with domain classification
        process_web_automation(
            tool_usage_id, 
            message_data, 
            domain_classification,  # Includes domain_category, intent_type, confidence
            routing_confidence
        )
    
    elif classification_target == 'web_search':
        process_web_search(tool_usage_id, message_data)
    
    elif classification_target == 'browser_automation':
        process_browser_automation(tool_usage_id, message_data, routing_confidence)
    
    # else: Keep in tool_usage only, no specialized table
```

---

## Schema Integration

### chat_sessions Table Fields

- **`user_query`**: User query from `request_body` (CRITICAL for domain classification)
- **`session_id`**: Primary key, used to link with other tables

### tool_usage Table Fields

- **`tool_type`**: Input to intent classifier (Stage 1: Tool Routing)
- **`step_type`**: Input to intent classifier (Stage 1: Tool Routing)
- **`classification_target`**: Output from intent classifier (Stage 1)
  - Values: `'web_search'`, `'browser_automation'`, `'web_automation'`, `'none'`

### browser_automations Table Fields

- **`tool_usage_id`**: Foreign key to `tool_usage` (after classification)
- **`classification_confidence`**: Confidence score from classifier (0.00-1.00)

### web_automations Table Fields

- **`tool_usage_id`**: Foreign key to `tool_usage` (after classification)
- **`domain_category`**: **INTENT CLASSIFIER OUTPUT** - Based on user_query analysis
  - Values: `'Shopping'`, `'Booking'`, `'Entertainment'`, `'Work'`, `'Education'`, `'Finance'`
- **`classification_confidence`**: Confidence score from domain classifier (0.00-1.00)

### domain_classifications Table

- **Purpose**: Reference/mapping table for intent classifier
- **Usage**: Stores query patterns and mappings (for reference, not direct lookup)
- **Note**: Actual classification happens via intent classifier analyzing `user_query`, not via table lookup

---

## Query Patterns

### Find all browser automations with their source tool_usage:

```sql
SELECT 
    ba.browser_action_id,
    ba.action_type,
    ba.classification_confidence,
    tu.tool_type,
    tu.step_type,
    tu.classification_target
FROM browser_automations ba
JOIN tool_usage tu ON ba.tool_usage_id = tu.tool_usage_id
WHERE ba.event_date >= CURRENT_DATE - 7;
```

### Find all web automations with classification details:

```sql
SELECT 
    wa.web_action_id,
    wa.action_type,
    wa.domain_category,
    wa.classification_confidence,
    tu.tool_type,
    tu.step_type,
    tu.classification_target
FROM web_automations wa
JOIN tool_usage tu ON wa.tool_usage_id = tu.tool_usage_id
WHERE wa.event_date >= CURRENT_DATE - 7;
```

### Count classifications by type:

```sql
SELECT 
    classification_target,
    COUNT(*) AS count,
    AVG(classification_confidence) AS avg_confidence
FROM tool_usage
WHERE classification_target IS NOT NULL
GROUP BY classification_target;
```

---

## Best Practices

1. **Always insert into tool_usage first**: This serves as the audit trail
2. **Update classification_target**: Store the classification result for analytics
3. **Store confidence scores**: Useful for quality monitoring and model improvement
4. **Handle unclassified records**: Records that don't match any route stay in `tool_usage` only
5. **Maintain referential integrity**: Use `tool_usage_id` as FK in specialized tables

---

## Monitoring and Validation

### Validate Classification Coverage:

```sql
-- Check for unclassified records
SELECT 
    COUNT(*) AS total_records,
    COUNT(classification_target) AS classified_records,
    COUNT(*) - COUNT(classification_target) AS unclassified_records,
    ROUND(100.0 * COUNT(classification_target) / NULLIF(COUNT(*), 0), 2) AS classification_rate
FROM tool_usage
WHERE event_date >= CURRENT_DATE - 7;
```

### Validate Routing:

```sql
-- Ensure all classified records have corresponding specialized table entries
SELECT 
    tu.classification_target,
    COUNT(DISTINCT tu.tool_usage_id) AS tool_usage_count,
    COUNT(DISTINCT CASE 
        WHEN tu.classification_target = 'browser_automation' THEN ba.browser_action_id
        WHEN tu.classification_target = 'web_automation' THEN wa.web_action_id
        WHEN tu.classification_target = 'web_search' THEN ws.search_id
    END) AS routed_count
FROM tool_usage tu
LEFT JOIN browser_automations ba ON tu.tool_usage_id = ba.tool_usage_id
LEFT JOIN web_automations wa ON tu.tool_usage_id = wa.tool_usage_id
LEFT JOIN web_searches ws ON tu.tool_usage_id = ws.tool_usage_id
WHERE tu.classification_target IS NOT NULL
  AND tu.event_date >= CURRENT_DATE - 7
GROUP BY tu.classification_target;
```

---

## Summary

The intent classifier workflow ensures that:
1. ✅ All tool usage events are captured in `tool_usage` (source of truth)
2. ✅ Classification logic is applied consistently
3. ✅ Records are routed to appropriate specialized tables
4. ✅ Classification metadata is stored for analytics
5. ✅ Referential integrity is maintained via `tool_usage_id` foreign keys

This design provides flexibility for future classification improvements while maintaining data integrity and query performance.

