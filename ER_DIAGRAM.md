# Entity-Relationship (ER) Diagram
## Redshift Chat Analytics Schema

This document provides an Entity-Relationship diagram of the Redshift schema for chat analytics, including the intent classifier workflow with domain/subdomain classification and support for multiple subdomains per message.

---

## Mermaid ER Diagram

```mermaid
erDiagram
    chat_messages {
        string message_id PK
        string room_id
        string thread_id
        datetime event_timestamp
        datetime request_timestamp
        datetime response_timestamp
        string tool_type
        string step_type
        string classification_target
        string domain
        string user_query
        boolean task_completed
        string task_completion_status
        string finish_reason
        string model
        string response_type
    }
    
    message_response_content {
        string message_id PK
        string response_content
        datetime insert_timestamp
    }
    
    tool_subdomains {
        int subdomain_id PK
        string message_id FK
        string subdomain
        datetime event_timestamp
    }
    
    usage_metrics {
        int metric_id PK
        string message_id FK
        string thread_id
        datetime event_timestamp
        datetime request_timestamp
        datetime response_timestamp
        int completion_tokens
        int prompt_tokens
        int total_tokens
        float input_tokens_cost
        float output_tokens_cost
        float request_cost
        float total_cost
        string search_context_size
        int latency_ms
    }
    
    chat_messages ||--|| message_response_content : has
    chat_messages ||--o{ tool_subdomains : has
    chat_messages ||--o{ usage_metrics : has
```

---

## Text-Based ER Diagram

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         CHAT ANALYTICS SCHEMA                           │
│                         Entity-Relationship Diagram                      │
└─────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────┐
│        chat_messages                │ ◄───────┐
│  ─────────────────────────────────  │         │ One-to-Many
│ PK message_id (PRIMARY KEY)        │         │
│    room_id (many-to-one)           │         │
│    thread_id (many-to-one)         │         │
│    event_timestamp (Sort Key)      │         │
│    request_timestamp               │         │
│    response_timestamp              │         │
│    tool_type                       │         │
│    step_type                        │         │
│    classification_target            │         │
│    domain (Source of Truth)         │         │
│    user_query (Intent Input)       │         │
│    task_completed                  │         │
│    task_completion_status          │         │
│    finish_reason                   │         │
│    model                           │         │
│    response_type                   │         │
│                                     │         │
│ Note: All tool classification      │         │
│ fields stored here                  │         │
└─────────────────────────────────────┘         │
         │                                        │
         │ 1:1                                    │
         ├────────────────────────────────────────┘
         │
         │ 1:1
         ▼
┌─────────────────────────────────────┐
│   message_response_content          │
│  ─────────────────────────────────  │
│ PK message_id (1:1)                │
│    response_content (Large TEXT)   │
│    insert_timestamp                │
└─────────────────────────────────────┘

         │ 1:N (one-to-many)                    │
         ▼                                       │
┌─────────────────────────────────────┐         │
│   tool_subdomains                   │ ────────┼───────┐
│  ─────────────────────────────────  │         │       │ Intent Classifier
│ PK subdomain_id                    │         │       │ Routes based on:
│ FK message_id                      │         │       │ - tool_type
│    subdomain (Source of Truth)     │         │       │ - step_type
│    event_timestamp                  │         │       │
│                                     │         │       │
│ Note: Junction table - one row     │         │       │
│ per subdomain intent                │         │       │
└─────────────────────────────────────┘         │       │
         │                                       │       │
         │ Optional FK (many-to-one)            │       │
         ▼                                       │       │
┌─────────────────────────────────────┐                 │
│      usage_metrics                  │                 │
│  ─────────────────────────────────  │                 │
│ PK metric_id                       │                 │
│ FK message_id (Optional)           │                 │
│    thread_id (many-to-one)         │                 │
│    event_timestamp (Sort Key)      │                 │
│    request_timestamp               │                 │
│    response_timestamp              │                 │
│    completion_tokens                │                 │
│    prompt_tokens                    │                 │
│    total_tokens                     │                 │
│    input_tokens_cost               │                 │
│    output_tokens_cost              │                 │
│    request_cost                    │                 │
│    total_cost                      │                 │
│    search_context_size             │                 │
│    latency_ms                      │                 │
└─────────────────────────────────────┘                 │
                                                        │
                                                        └─────────────────────┘
```

---

## Intent Classifier Workflow

```
┌─────────────────────────────────────────────────────────────────┐
│                    INTENT CLASSIFIER WORKFLOW                  │
│              (Multiple Subdomains Per Message Support)           │
└─────────────────────────────────────────────────────────────────┘

1. RAW DATA (from topic message)
   └─> reasoning_steps[] array
        │
        ▼
2. INSERT INTO chat_messages
   ├─ user_query (from request_body.messages[0].content)
   ├─ tool_type (from Glue classifier selection)
   ├─ step_type (from selected reasoning step)
   └─ Other message metadata
        │
        ▼
3. INTENT CLASSIFIER (Stage 1: Tool Routing)
   ├─ Input: tool_type + step_type (from reasoning_steps[])
   ├─ Process: Classification logic
   └─ Output: classification_target
        │
        ├─ tool_type = 'web_search'
        │   └─> UPDATE chat_messages SET classification_target='web_search'
        │
        ├─ tool_type = 'browser_tool_execution'
        │   ├─ IF step_type = 'ENTROPY_REQUEST'
        │   │   └─> UPDATE chat_messages SET classification_target='web_automation'
        │   └─ ELSE
        │       └─> UPDATE chat_messages SET classification_target='browser_automation'
        │
        └─ tool_type = 'agent_progress'
            ├─ IF step_type = 'ENTROPY_REQUEST'
            │   └─> UPDATE chat_messages SET classification_target='web_automation'
            └─ ELSE
                └─> UPDATE chat_messages SET classification_target='none' (planning/reasoning only)

4. INTENT CLASSIFIER (Stage 2: Domain/Subdomain Classification)
   ├─ Input: user_query (from chat_messages.user_query)
   ├─ Process: Analyze user_query to identify intents
   └─ Output: domain + subdomain(s) (can be multiple intents)
        │
        ├─ Example: "order food and schedule delivery"
        │   └─> UPDATE chat_messages SET domain='Transactional'
        │   └─> INSERT INTO tool_subdomains (message_id, subdomain='food_order')
        │   └─> INSERT INTO tool_subdomains (message_id, subdomain='delivery')
        │
        ├─ Example: "book a hotel room"
        │   └─> UPDATE chat_messages SET domain='Transactional'
        │   └─> INSERT INTO tool_subdomains (message_id, subdomain='booking')
        │
        └─ Example: "search for restaurant reviews"
            └─> UPDATE chat_messages SET domain='Informational'
            └─> INSERT INTO tool_subdomains (message_id, subdomain='restaurant_info')

5. STORAGE
   └─ All tool classification fields stored in chat_messages
       ├─ tool_type, step_type, classification_target, domain (SOURCE OF TRUTH)
       └─ Individual subdomains stored in tool_subdomains table (one row per subdomain)
       Note: domain calculated from chat_messages.user_query and stored in chat_messages
       Note: subdomains calculated from chat_messages.user_query and stored in tool_subdomains
```

---

## Relationship Summary

### Core Relationships:

1. **chat_messages** → **message_response_content** (1:1)
   - One message has exactly one response content (or NULL)
   - FK: `message_response_content.message_id` → `chat_messages.message_id` (PRIMARY KEY)
   - **Best Practice**: Large content separated for performance

2. **chat_messages** → **tool_subdomains** (1:N)
   - One message can have multiple subdomain records (one row per subdomain)
   - FK: `tool_subdomains.message_id` → `chat_messages.message_id`
   - **Multiple Subdomains**: Each subdomain intent stored as a separate row (normalized structure)
   - **Subdomain**: Calculated by intent classifier from `chat_messages.user_query` and stored in `tool_subdomains` (SOURCE OF TRUTH)
   - **Domain**: Domain is stored in `chat_messages` table (join required for domain+subdomain queries)

3. **chat_messages** → **usage_metrics** (1:N, optional)
   - One message can have multiple usage metric records (optional FK)
   - FK: `usage_metrics.message_id` → `chat_messages.message_id` (optional)
   - Many metrics can belong to one thread_id (many-to-one relationship)

---

## Key Design Features

### Distribution Keys (DISTKEY):
- All fact tables: **EVEN distribution** (no DISTKEY specified)
  - `thread_id` and `room_id` have low cardinality (many messages per thread/room), not suitable for distribution

### Sort Keys (SORTKEY):
- Time-series tables: `event_timestamp` as first sort key
- Composite sort keys for common query patterns:
  - `chat_messages`: `SORTKEY(event_timestamp, thread_id)`
  - `tool_subdomains`: `SORTKEY(message_id, subdomain)` (for joins and filtering)
  - `usage_metrics`: `SORTKEY(event_timestamp, thread_id)`
  - `message_response_content`: `SORTKEY(message_id)`

### Intent Classifier Integration:
- **Source**: `chat_messages.user_query` (input for intent classifier)
- **Classification Basis**: Based on `response_body`, `step_type`, and `tool` fields from JSON
- **One Tool Per Message**: Classifier selects ONE tool per message (others discarded if multiple exist)
- **Multiple Subdomains Per Message**: ONE tool_type can have MULTIPLE intents in a single message (stored in normalized `tool_subdomains` junction table - one row per subdomain)
- **Two-Stage Classification**:
  1. **Tool Routing**: Based on `tool_type` and `step_type` combination
     - `tool_type='web_search'` → `classification_target='web_search'` → stored in `chat_messages`
     - `tool_type='browser_tool_execution' AND step_type != 'ENTROPY_REQUEST'` → `classification_target='browser_automation'` → stored in `chat_messages`
     - `tool_type='browser_tool_execution' AND step_type='ENTROPY_REQUEST'` → `classification_target='web_automation'` → stored in `chat_messages`
     - `tool_type='agent_progress' AND step_type='ENTROPY_REQUEST'` → `classification_target='web_automation'` → stored in `chat_messages`
     - `tool_type='agent_progress' AND step_type != 'ENTROPY_REQUEST'` → `classification_target='none'` → stored in `chat_messages`
     - **Key Rule**: `step_type='ENTROPY_REQUEST'` always routes to `classification_target='web_automation'` (actual web action)
  2. **Domain/Subdomain Classification**: Based on `user_query` analysis
     - Intent classifier analyzes `user_query` from `chat_messages.user_query`
     - Outputs `domain` (e.g., 'Transactional', 'Informational', 'Entertainment', 'Productivity') → stored in `chat_messages`
     - Outputs `subdomain`(s) (e.g., 'food_order', 'delivery' for multiple intents, 'shopping', 'booking' for single intent) → stored in `tool_subdomains` (one row per subdomain)
     - **Multiple Intents Support**: Can identify and store multiple subdomain intents as separate rows in `tool_subdomains` (e.g., 'food_order' and 'delivery' as two separate rows)
     - `domain` stored directly in `chat_messages` (SOURCE OF TRUTH)
     - `subdomain` values stored in `tool_subdomains` (SOURCE OF TRUTH - one row per subdomain)
- **Tracking**: `tool_type`, `step_type`, `classification_target`, `domain` in `chat_messages`, `subdomain` in `tool_subdomains` (SOURCE OF TRUTH)

---

## Notes

1. **Foreign Key Constraints**: Redshift doesn't enforce FK constraints, but relationships are maintained logically through ETL

2. **Domain/Subdomain Storage**: 
   - `domain` is stored in `chat_messages` (SOURCE OF TRUTH)
   - `subdomain` values are stored in `tool_subdomains` junction table (SOURCE OF TRUTH) - one row per subdomain
   - Calculated by intent classifier from `chat_messages.user_query`
   - All tool classification fields (tool_type, step_type, classification_target, domain) stored directly in `chat_messages`
   - Normalized structure enables better querying and analytics on individual subdomains

3. **ETL Workflow**: Intent classifier runs after `chat_messages` insert, updating `chat_messages` with tool classification fields and calculating domain/subdomain from `user_query`

4. **Domain/Subdomain Classification**: Done by intent classifier analyzing `user_query` from `chat_messages.user_query`, NOT via table lookup

5. **One Tool Per Message**: Classifier selects ONE tool per message - if multiple tools exist in JSON, others are discarded

6. **Multiple Subdomains Per Message**: ONE tool_type can have MULTIPLE intents in a single message - stored in normalized `tool_subdomains` junction table (one row per subdomain, e.g., 'food_order' and 'delivery' as separate rows)

7. **Source of Truth**: 
   - `chat_messages.domain` is the SOURCE OF TRUTH for domain
   - `tool_subdomains.subdomain` is the SOURCE OF TRUTH for individual subdomains (one row per subdomain)
   - Calculated from `chat_messages.user_query` by intent classifier

8. **Large Content Separation**: `message_response_content` separated from `chat_messages` for performance (Redshift best practice)

9. **EVEN Distribution**: No DISTKEY specified (EVEN distribution) - `thread_id` and `room_id` have low cardinality, not suitable for distribution

10. **Relationship Fields**: `thread_id` and `room_id` are NOT unique identifiers of a message - they are relationship fields (many messages can belong to one thread/room)

11. **Consolidated Schema**: All tool classification fields (`tool_type`, `step_type`, `classification_target`, `domain`) are stored directly in `chat_messages` table, eliminating the need for a separate `tool_actions` table. This simplifies the schema while maintaining all functionality.

12. **Junction Table for Subdomains**: `tool_subdomains` is a normalized junction table that stores one row per subdomain intent. This enables better querying and analytics on individual subdomains compared to comma-separated values.

---

## Visualization Tools

This diagram can be rendered using:
- **Mermaid**: View in GitHub, GitLab, or Mermaid Live Editor
- **VS Code**: With Mermaid preview extension
- **Online**: https://mermaid.live/

For text-based viewing, see the ASCII diagram above.

---

## Example Queries Using Multiple Subdomains

```sql
-- Find all messages with "food_order" intent (using normalized junction table)
SELECT DISTINCT cm.*
FROM chat_messages cm
JOIN tool_subdomains ts ON cm.message_id = ts.message_id
WHERE cm.tool_type = 'web_automation'
  AND cm.domain = 'Transactional' 
  AND ts.subdomain = 'food_order';

-- Find all messages with both "food_order" AND "delivery" (same message has both)
SELECT cm.*
FROM chat_messages cm
WHERE cm.tool_type = 'web_automation'
  AND cm.domain = 'Transactional'
  AND cm.message_id IN (
      SELECT message_id FROM tool_subdomains WHERE subdomain = 'food_order'
  )
  AND cm.message_id IN (
      SELECT message_id FROM tool_subdomains WHERE subdomain = 'delivery'
  );

-- Count messages by individual subdomain (easy with normalized structure)
SELECT 
    ts.subdomain,
    COUNT(DISTINCT ts.message_id) as message_count,
    COUNT(*) as subdomain_occurrence_count
FROM tool_subdomains ts
JOIN chat_messages cm ON ts.message_id = cm.message_id
WHERE cm.tool_type = 'web_automation'
  AND cm.domain = 'Transactional'
GROUP BY ts.subdomain
ORDER BY message_count DESC;

-- Count messages with multiple subdomains
SELECT 
    ts.message_id,
    COUNT(*) as subdomain_count,
    LISTAGG(ts.subdomain, ', ') WITHIN GROUP (ORDER BY ts.subdomain) as subdomains
FROM tool_subdomains ts
JOIN chat_messages cm ON ts.message_id = cm.message_id
WHERE cm.tool_type = 'web_automation'
  AND cm.domain = 'Transactional'
GROUP BY ts.message_id
HAVING COUNT(*) > 1;

-- Cross-tool-type analytics
SELECT tool_type, classification_target, COUNT(*) as message_count
FROM chat_messages
GROUP BY tool_type, classification_target;

-- Join with chat_messages to get user_query and all subdomains
SELECT 
    cm.tool_type,
    cm.domain,
    ts.subdomain,
    cm.user_query
FROM chat_messages cm
JOIN tool_subdomains ts ON cm.message_id = ts.message_id
WHERE cm.domain = 'Transactional'
ORDER BY cm.message_id, ts.subdomain;

-- Get all subdomains for a specific message
SELECT 
    ts.subdomain,
    cm.domain,
    cm.tool_type
FROM tool_subdomains ts
JOIN chat_messages cm ON ts.message_id = cm.message_id
WHERE ts.message_id = 'your_message_id_here';
```
