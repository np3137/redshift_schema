# Schema Normalization Update
## Moving response_body fields to responses table

---

## Issue Identified

The original schema had `status` and `type` fields in `chat_sessions` table, but these fields are actually part of `response_body` in the topic message structure.

**Problem**: Violates normalization best practices - response-level data should be in responses table, not session table.

---

## Best Practice Applied

### Normalization Rule:
**Data should be stored in the table that matches its source and scope**
- Session-level data (`_id`, `thread_id`, `@timestamp`, `request_body`) → `chat_sessions`
- Response-level data (`response_body.*`) → `responses`

---

## Changes Made

### 1. `chat_sessions` Table - REMOVED fields:
- ❌ `model` (moved to `responses`)
- ❌ `status` (moved to `responses`)
- ❌ `type` (moved to `responses`)

**Reason**: These fields are in `response_body`, not session-level data

### 2. `responses` Table - ADDED fields:
- ✅ `status` - From `response_body.status`
- ✅ `type` - From `response_body.type`
- ✅ `object` - From `response_body.object` (e.g., 'chat.completion.done')
- ✅ `created_timestamp` - From `response_body.created`

**Reason**: All response_body fields belong in responses table

### 3. `chat_sessions` Table - KEPT fields:
- ✅ `task_completed` - Derived/computed field (can be at session level)
- ✅ `task_completion_status` - Derived/computed field
- ✅ `task_completion_reason` - Derived/computed field

**Reason**: Task completion is a session-level concept, even if derived from response

---

## Topic Message Structure Mapping

### Corrected Mapping:

```json
{
  // TOP-LEVEL → chat_sessions
  "_id": {"$oid": "..."},              // → chat_sessions.session_id
  "room_id": "",                       // → chat_sessions.room_id
  "thread_id": "...",                  // → chat_sessions.thread_id
  "@timestamp": 1761126835.345874,     // → chat_sessions.event_timestamp
  "timestamp": {"$date": "..."},       // → chat_sessions.created_timestamp
  
  // REQUEST_BODY → Various tables (browser_history, etc.)
  "request_body": {
    "browser_history": [...],          // → browser_history
    ...
  },
  
  // RESPONSE_BODY → responses table
  "response_body": {
    "id": "...",                       // → responses.response_id (PK)
    "created": 1761126835,             // → responses.created_timestamp
    "model": "sonar-pro",              // → responses.model
    "status": "COMPLETED",             // → responses.status
    "type": "end_of_stream",           // → responses.type
    "object": "chat.completion.done",  // → responses.object
    "usage": {...},                    // → usage_metrics
    "choices": [{
      "finish_reason": "stop",         // → responses.finish_reason
      "message": {
        "content": "...",              // → responses.response_content
        "reasoning_steps": [...]       // → tool_usage, web_searches, etc.
      }
    }]
  }
}
```

---

## Benefits of This Normalization

### 1. Data Integrity
- ✅ Response fields are together in one table
- ✅ No duplication of response data in session table
- ✅ Clear separation of concerns

### 2. Query Performance
- ✅ Can query session without loading response data
- ✅ Can query response status without loading session data
- ✅ Better compression (response data grouped together)

### 3. Maintainability
- ✅ Clear data lineage (response_body → responses table)
- ✅ Easier ETL (response_body fields go to one table)
- ✅ Follows single source of truth principle

### 4. Schema Clarity
- ✅ `chat_sessions` = Session metadata
- ✅ `responses` = Response metadata + content
- ✅ Clear distinction between session and response concepts

---

## Updated ETL Requirements

### For `chat_sessions`:
```python
# Extract from TOP-LEVEL only
session_data = {
    'session_id': message['_id']['$oid'],
    'room_id': message.get('room_id'),
    'thread_id': message['thread_id'],
    'event_timestamp': message['@timestamp'],
    'created_timestamp': message.get('timestamp', {}).get('$date'),
    'response_id': message.get('response_body', {}).get('id'),  # FK only
    # NO model, status, type here - those go to responses
}
```

### For `responses`:
```python
# Extract from response_body
response_body = message.get('response_body', {})
response_data = {
    'response_id': response_body.get('id'),  # PK
    'session_id': message['_id']['$oid'],    # FK
    'thread_id': message['thread_id'],       # For filtering
    'event_timestamp': message['@timestamp'],
    'created_timestamp': response_body.get('created'),
    'model': response_body.get('model'),
    'status': response_body.get('status'),    # MOVED HERE
    'type': response_body.get('type'),        # MOVED HERE
    'object': response_body.get('object'),    # NEW
    'response_content': extract_content(response_body),
    'finish_reason': extract_finish_reason(response_body),
}
```

---

## Updated Query Examples

### Query 1: Sessions with Response Status
```sql
-- Join to get response status
SELECT 
    cs.session_id,
    cs.thread_id,
    cs.event_timestamp,
    r.status,
    r.type,
    r.model,
    r.finish_reason
FROM chat_sessions cs
LEFT JOIN responses r ON cs.response_id = r.response_id
WHERE r.status = 'COMPLETED';
```

### Query 2: Task Completion Analysis
```sql
-- Task completion with response status
SELECT 
    cs.task_completed,
    r.status AS response_status,
    r.type AS response_type,
    COUNT(*) AS count
FROM chat_sessions cs
LEFT JOIN responses r ON cs.response_id = r.response_id
WHERE cs.task_completed IS NOT NULL
GROUP BY cs.task_completed, r.status, r.type;
```

### Query 3: Session Status Distribution
```sql
-- Response status distribution
SELECT 
    r.status,
    r.type,
    COUNT(*) AS session_count
FROM chat_sessions cs
JOIN responses r ON cs.response_id = r.response_id
GROUP BY r.status, r.type
ORDER BY session_count DESC;
```

---

## Migration Notes

If you have existing data:

### Step 1: Add new fields to responses
```sql
ALTER TABLE responses 
ADD COLUMN status VARCHAR(50),
ADD COLUMN type VARCHAR(50),
ADD COLUMN object VARCHAR(50),
ADD COLUMN created_timestamp TIMESTAMP;
```

### Step 2: Migrate data
```sql
-- Move status, type from chat_sessions to responses
-- This requires matching session_id and response_id
UPDATE responses r
SET 
    status = cs.status,
    type = cs.type,
    created_timestamp = cs.created_timestamp
FROM chat_sessions cs
WHERE r.session_id = cs.session_id
    AND r.response_id = cs.response_id;
```

### Step 3: Remove fields from chat_sessions
```sql
ALTER TABLE chat_sessions
DROP COLUMN status,
DROP COLUMN type,
DROP COLUMN model;
```

---

## Best Practices Followed

✅ **Single Responsibility**: Each table has clear purpose
✅ **Normalization**: Response data in responses table
✅ **Data Lineage**: Clear mapping from source to table
✅ **Query Efficiency**: Can query session without response data
✅ **Maintainability**: Easier to understand and modify

---

## Summary

**Changes**:
- ✅ Removed `status`, `type`, `model` from `chat_sessions`
- ✅ Added `status`, `type`, `object`, `created_timestamp` to `responses`
- ✅ Maintained task completion fields in `chat_sessions` (derived fields)

**Result**: Proper normalization following Redshift best practices!

