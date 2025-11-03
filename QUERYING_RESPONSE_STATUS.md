# Querying Response Status (After Normalization)

## Overview

After normalizing the schema, `status`, `type`, and `model` fields are now in the `responses` table (where they belong, as they're from `response_body`). This document shows how to query these fields correctly.

---

## Query Patterns

### 1. Basic: Get Session with Response Status

```sql
-- Join chat_sessions with responses to get status
SELECT 
    cs.session_id,
    cs.thread_id,
    cs.event_timestamp,
    r.status AS response_status,
    r.type AS response_type,
    r.model AS response_model
FROM chat_sessions cs
LEFT JOIN responses r ON cs.response_id = r.response_id;
```

### 2. Filter by Response Status

```sql
-- Get all completed sessions
SELECT 
    cs.session_id,
    cs.thread_id,
    cs.task_completed,
    r.status,
    r.type
FROM chat_sessions cs
JOIN responses r ON cs.response_id = r.response_id
WHERE r.status = 'COMPLETED';
```

### 3. Using Helper View (Recommended)

```sql
-- Use the helper view for convenience
SELECT 
    session_id,
    thread_id,
    response_status,
    response_type,
    model
FROM v_sessions_with_responses
WHERE response_status = 'COMPLETED';
```

### 4. Count by Response Status

```sql
-- Count sessions by response status
SELECT 
    r.status,
    r.type,
    COUNT(*) AS session_count
FROM chat_sessions cs
JOIN responses r ON cs.response_id = r.response_id
GROUP BY r.status, r.type
ORDER BY session_count DESC;
```

### 5. Response Status with Task Completion

```sql
-- Analyze task completion vs response status
SELECT 
    cs.task_completed,
    r.status AS response_status,
    COUNT(*) AS count
FROM chat_sessions cs
JOIN responses r ON cs.response_id = r.response_id
WHERE cs.task_completed IS NOT NULL
GROUP BY cs.task_completed, r.status;
```

---

## Materialized View Usage

The `mv_task_completion_stats` materialized view includes response status:

```sql
-- Fast query using materialized view
SELECT 
    completion_date,
    response_status,
    task_completion_status,
    completed_count,
    failed_count,
    completion_rate_percent
FROM mv_task_completion_stats
WHERE response_status = 'COMPLETED'
    AND completion_date >= CURRENT_DATE - 7;
```

---

## Performance Considerations

### ✅ Good: Query Response Status
```sql
-- Uses helper view (pre-joined)
SELECT * FROM v_sessions_with_responses 
WHERE response_status = 'COMPLETED';
```

### ✅ Good: Join on DISTKEY
```sql
-- Both tables use session_id as DISTKEY
SELECT * 
FROM chat_sessions cs
JOIN responses r ON cs.session_id = r.session_id  -- DISTKEY match
WHERE r.status = 'COMPLETED';
```

### ⚠️ Monitor: Join on response_id
```sql
-- Join on response_id (not DISTKEY)
-- Still efficient if response_id has high cardinality
SELECT * 
FROM chat_sessions cs
JOIN responses r ON cs.response_id = r.response_id
WHERE r.status = 'COMPLETED';
```

---

## ETL Data Flow

### Step 1: Insert into chat_sessions
```python
# Extract from TOP-LEVEL only
chat_session = {
    'session_id': message['_id']['$oid'],
    'thread_id': message['thread_id'],
    'event_timestamp': message['@timestamp'],
    'response_id': response_body.get('id'),  # FK only
    # NO model, status, type here
}
```

### Step 2: Insert into responses
```python
# Extract from response_body
response = {
    'response_id': response_body['id'],  # PK
    'session_id': message['_id']['$oid'],  # FK
    'model': response_body.get('model'),
    'status': response_body.get('status'),  # MOVED HERE
    'type': response_body.get('type'),      # MOVED HERE
    'object': response_body.get('object'),   # NEW
    'created_timestamp': response_body.get('created'),
    'response_content': extract_content(response_body),
    'finish_reason': extract_finish_reason(response_body),
}
```

---

## Migration Queries (If Needed)

If you have existing data with status/type in chat_sessions:

```sql
-- Step 1: Add fields to responses (if not exists)
ALTER TABLE responses 
ADD COLUMN status VARCHAR(50),
ADD COLUMN type VARCHAR(50),
ADD COLUMN object VARCHAR(50),
ADD COLUMN created_timestamp TIMESTAMP;

-- Step 2: Migrate data (if applicable)
-- Note: This assumes you have a way to match old data
-- May require manual ETL re-processing
```

---

## Summary

**Before Normalization** (❌ Not Best Practice):
- `status`, `type`, `model` in `chat_sessions` (but they're from `response_body`)

**After Normalization** (✅ Best Practice):
- `status`, `type`, `model` in `responses` table (where they belong)

**Query Pattern**:
- Always JOIN `responses` table to get response-level fields
- Use helper view `v_sessions_with_responses` for convenience
- JOIN on `response_id` or `session_id` (both are efficient)

