# Schema Update: Response ID Normalization

## Issue
The `chat_sessions` table was storing `response_id` without a corresponding `responses` table, creating an orphaned foreign key reference.

## Solution
Created a new `responses` table to properly normalize response data from topic messages.

## Changes Made

### 1. Added `responses` Table (01_base_tables.sql)
```sql
CREATE TABLE responses (
    response_id VARCHAR(255) NOT NULL,
    session_id VARCHAR(255) NOT NULL,
    thread_id VARCHAR(255) NOT NULL,
    event_timestamp TIMESTAMP NOT NULL,
    response_content TEXT, -- From choices[].message.content
    finish_reason VARCHAR(50), -- 'stop', etc.
    model VARCHAR(100),
    insert_timestamp TIMESTAMP DEFAULT GETDATE(),
    
    DISTKEY(thread_id),
    SORTKEY(event_timestamp, thread_id)
)
```

**Data Source**: 
- `response_id` ← `response_body.id`
- `response_content` ← `response_body.choices[].message.content`
- `finish_reason` ← `response_body.choices[].finish_reason`
- `model` ← `response_body.model`

### 2. Updated `chat_sessions` Table
- Added comment clarifying `response_id` is a FK to `responses` table
- Removed redundant `finish_reason` (now in `responses` table)

### 3. Updated Phase 2 Tables
- `user_feedback.response_id` - Now references `responses` table
- `test_data_collection.response_id` - Now references `responses` table
- Added comments clarifying FK relationships

### 4. Added Helper View
- `v_sessions_with_responses` - Joins `chat_sessions` with `responses` for easy querying

## Data Extraction from Topic Message

### Topic Message Structure:
```json
{
  "response_body": {
    "id": "c798fc9a-e079-4429-bc71-62a6096c6b74",  // → response_id
    "model": "sonar-pro",                           // → model
    "choices": [{
      "finish_reason": "stop",                      // → finish_reason
      "message": {
        "content": "...",                           // → response_content
        "reasoning_steps": [...]                    // → already in tool_usage
      }
    }]
  }
}
```

## Benefits

1. **Normalization**: Response content is stored once, referenced by ID
2. **Data Integrity**: Clear FK relationship between sessions and responses
3. **Phase 2 Ready**: `test_data_collection` can properly reference responses
4. **Query Efficiency**: Can query responses independently or join as needed
5. **Storage Optimization**: Response content (can be large) stored separately from session metadata

## ETL Changes Required

When loading data, extract:
1. `response_body.id` → `responses.response_id`
2. `response_body.choices[].message.content` → `responses.response_content`
3. `response_body.choices[].finish_reason` → `responses.finish_reason`
4. `response_body.model` → `responses.model`
5. `response_body.id` → `chat_sessions.response_id` (FK reference)

## Query Examples

### Get session with response content:
```sql
SELECT * FROM v_sessions_with_responses 
WHERE thread_id = 'your_thread_id';
```

### Get responses without session details:
```sql
SELECT * FROM responses 
WHERE thread_id = 'your_thread_id'
ORDER BY event_timestamp DESC;
```

### Join session to response for feedback analysis (Phase 2):
```sql
SELECT 
    uf.feedback_type,
    r.response_content,
    cs.model
FROM user_feedback uf
JOIN responses r ON uf.response_id = r.response_id
JOIN chat_sessions cs ON r.session_id = cs.session_id;
```

