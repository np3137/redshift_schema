# Entity-Relationship (ER) Diagram
## Redshift Chat Analytics Schema

This document provides an Entity-Relationship diagram of the Redshift schema for chat analytics, including the intent classifier workflow with domain/subdomain classification and support for multiple subdomains per message.

---

## Mermaid ER Diagram

```mermaid
erDiagram
    chat_messages {
        VARCHAR message_id PK
        VARCHAR room_id
        VARCHAR thread_id
        TIMESTAMP event_timestamp
        TIMESTAMP request_timestamp
        TIMESTAMP response_timestamp
        VARCHAR response_id
        VARCHAR user_query
        VARCHAR domain
        VARCHAR tool_type
        BOOLEAN task_completed
        VARCHAR task_completion_status
        VARCHAR finish_reason
        VARCHAR model
        VARCHAR response_type
        TIMESTAMP insert_timestamp
    }
    
    message_response_content {
        VARCHAR message_id PK
        VARCHAR response_content
        TIMESTAMP insert_timestamp
    }
    
    tool_usage {
        BIGINT tool_usage_id PK
        VARCHAR message_id UNIQUE
        TIMESTAMP event_timestamp
        VARCHAR tool_type
        VARCHAR step_type
        VARCHAR classification_target
    }
    
    web_searches {
        BIGINT search_id PK
        BIGINT tool_usage_id FK
        VARCHAR message_id UNIQUE
        TIMESTAMP event_timestamp
        VARCHAR search_type
        VARCHAR search_keywords
        INTEGER num_results
        VARCHAR domain
        VARCHAR subdomain
    }
    
    browser_automations {
        BIGINT browser_action_id PK
        BIGINT tool_usage_id FK
        VARCHAR message_id UNIQUE
        TIMESTAMP event_timestamp
        VARCHAR domain
        VARCHAR subdomain
    }
    
    web_automations {
        BIGINT web_action_id PK
        BIGINT tool_usage_id FK
        VARCHAR message_id UNIQUE
        TIMESTAMP event_timestamp
        VARCHAR domain
        VARCHAR subdomain
    }
    
    usage_metrics {
        BIGINT metric_id PK
        VARCHAR message_id FK
        VARCHAR thread_id
        TIMESTAMP event_timestamp
        TIMESTAMP request_timestamp
        TIMESTAMP response_timestamp
        INTEGER completion_tokens
        INTEGER prompt_tokens
        INTEGER total_tokens
        DOUBLE input_tokens_cost
        DOUBLE output_tokens_cost
        DOUBLE request_cost
        DOUBLE total_cost
        VARCHAR search_context_size
        INTEGER latency_ms
        VARCHAR model
        TIMESTAMP insert_timestamp
    }
    
    domain_classifications {
        VARCHAR domain_name PK
        VARCHAR domain_category
        VARCHAR subcategory
        VARCHAR intent_type
        VARCHAR query_patterns
        BOOLEAN is_active
        TIMESTAMP created_timestamp
        TIMESTAMP updated_timestamp
    }
    
    chat_messages ||--|| message_response_content
    chat_messages ||--|| tool_usage
    tool_usage ||--o| web_searches
    tool_usage ||--o| browser_automations
    tool_usage ||--o| web_automations
    chat_messages ||--o{ usage_metrics
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
│    response_id                     │         │
│    user_query (Intent Input)       │         │
│    domain (Source of Truth)        │         │
│    tool_type (Denormalized)        │         │
│    task_completed                  │         │
│    task_completion_status          │         │
│    finish_reason                   │         │
│    model                           │         │
│    response_type                   │         │
│    insert_timestamp                │         │
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

         │ 1:1
         ▼
┌─────────────────────────────────────┐
│        tool_usage                   │ ───────────────┐
│  ─────────────────────────────────  │                 │ Intent Classifier
│ PK tool_usage_id                   │                 │ Routes based on:
│    message_id UNIQUE (1:1)         │                 │ - tool_type
│    event_timestamp (Sort Key)      │                 │ - step_type
│    tool_type                        │                 │
│    step_type                        │                 │
│    classification_target            │                 │
└─────────────────────────────────────┘                 │
         │                                               │
         │ Routes to specialized tables                  │
         │                                               │
    ┌────┴────┬────────────┬────────────────────────────┘
    │         │            │
    ▼         ▼            ▼
┌──────────┐ ┌──────────────┐ ┌──────────────┐
│web_      │ │browser_      │ │web_          │
│searches  │ │automations   │ │automations   │
│──────────│ │──────────────│ │──────────────│
│PK search_│ │PK browser_   │ │PK web_action_│
│  id      │ │  action_id   │ │  id          │
│FK tool_  │ │FK tool_usage_│ │FK tool_usage_│
│  usage_id│ │  id          │ │  id          │
│FK message│ │FK message_id │ │FK message_id │
│  _id     │ │  (UNIQUE)    │ │  (UNIQUE)    │
│  (UNIQUE)│ │              │ │              │
│    search│ │              │ │              │
│    _type │ │              │ │              │
│    search│ │              │ │              │
│    _keyw │ │              │ │              │
│    ords  │ │              │ │              │
│    num_r │ │              │ │              │
│    esults│ │              │ │              │
│    domain│ │    domain    │ │    domain    │
│    subdom│ │    subdomain  │ │    subdomain │
│    ain   │ │    (multiple) │ │    (multiple)│
└──────────┘ └──────────────┘ └──────────────┘
         │
         │ Optional FK (many-to-one)
         ▼
┌─────────────────────────────────────┐
│      usage_metrics                  │
│  ─────────────────────────────────  │
│ PK metric_id                       │
│ FK message_id (Optional)           │
│    thread_id (many-to-one)         │
│    event_timestamp (Sort Key)      │
│    request_timestamp               │
│    response_timestamp              │
│    completion_tokens                │
│    prompt_tokens                    │
│    total_tokens                     │
│    input_tokens_cost               │
│    output_tokens_cost              │
│    request_cost                    │
│    total_cost                      │
│    search_context_size             │
│    latency_ms                      │
│    model                           │
│    insert_timestamp                │
└─────────────────────────────────────┘

┌─────────────────────────────────────┐
│  domain_classifications             │
│  ─────────────────────────────────  │
│ PK domain_name (DISTKEY)           │
│    domain_category (Sort Key)     │
│    subcategory                     │
│    intent_type (Sort Key)          │
│    query_patterns (Reference only) │
│    is_active                       │
│    created_timestamp               │
│    updated_timestamp               │
└─────────────────────────────────────┘
         │
         │ Reference Table (for training/examples)
         │ NOT used for ETL classification
         └─────────────────────────────────────┘
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
2. INSERT INTO tool_usage
   ├─ tool_type = 'web_search'
   ├─ tool_type = 'browser_tool_execution'
   └─ tool_type = 'agent_progress'
        │
        ▼
3. INTENT CLASSIFIER (Stage 1: Tool Routing)
   ├─ Input: tool_type + step_type
   ├─ Process: Classification logic
   └─ Output: classification_target
        │
        ├─ tool_type = 'web_search'
        │   └─> INSERT INTO web_searches
        │
        ├─ tool_type = 'browser_tool_execution'
        │   ├─ IF step_type = 'ENTROPY_REQUEST'
        │   │   └─> INSERT INTO web_automations (actual web action)
        │   └─ ELSE
        │       └─> INSERT INTO browser_automations (browser tool execution)
        │
        └─ tool_type = 'agent_progress'
            ├─ IF step_type = 'ENTROPY_REQUEST'
            │   └─> INSERT INTO web_automations (actual web action)
            └─ ELSE
                └─> Stays in tool_usage only (planning/reasoning)

4. INTENT CLASSIFIER (Stage 2: Domain/Subdomain Classification)
   ├─ Input: user_query (from request_body.messages[0].content)
   ├─ Process: Analyze user_query to identify intents
   └─ Output: domain + subdomain (can be multiple intents)
        │
        ├─ Example: "order food and schedule delivery"
        │   └─> domain = 'Transactional'
        │   └─> subdomain = 'food_order,delivery' (multiple intents)
        │
        ├─ Example: "book a hotel room"
        │   └─> domain = 'Transactional'
        │   └─> subdomain = 'booking'
        │
        └─ Example: "search for restaurant reviews"
            └─> domain = 'Informational'
            └─> subdomain = 'restaurant_info'

5. STORAGE
   ├─ INSERT INTO chat_messages (source of truth for domain)
   │   └─ domain (stored here)
   │
   └─ INSERT INTO specialized tables (subdomain stored here)
       ├─ web_searches.domain, web_searches.subdomain
       ├─ browser_automations.domain, browser_automations.subdomain
       └─ web_automations.domain, web_automations.subdomain
       Note: subdomain is calculated by intent classifier and stored
       directly in specialized tables (not in chat_messages)
```

---

## Relationship Summary

### Core Relationships:

1. **chat_messages** → **message_response_content** (1:1)
   - One message has exactly one response content (or NULL)
   - FK: `message_response_content.message_id` → `chat_messages.message_id` (PRIMARY KEY)
   - **Best Practice**: Large content separated for performance

2. **chat_messages** → **tool_usage** (1:1)
   - One message has exactly one tool usage event (or NULL)
   - FK: `tool_usage.message_id` → `chat_messages.message_id` (UNIQUE)
   - **Key Rule**: Classifier selects ONE tool per message (others discarded if multiple exist)

3. **tool_usage** → **web_searches** (1:0..1)
   - One tool usage can result in one web search
   - FK: `web_searches.tool_usage_id` → `tool_usage.tool_usage_id`
   - FK: `web_searches.message_id` → `chat_messages.message_id` (UNIQUE)
   - **Intent Classifier**: `classification_target = 'web_search'`
   - **Domain**: Denormalized from `chat_messages.domain`
   - **Subdomain**: Calculated by intent classifier, stored directly in `web_searches` (supports multiple intents as comma-separated)

4. **tool_usage** → **browser_automations** (1:0..1)
   - One tool usage can result in one browser automation
   - FK: `browser_automations.tool_usage_id` → `tool_usage.tool_usage_id`
   - FK: `browser_automations.message_id` → `chat_messages.message_id` (UNIQUE)
   - **Intent Classifier**: `classification_target = 'browser_automation'`
   - **Domain**: Denormalized from `chat_messages.domain`
   - **Subdomain**: Calculated by intent classifier, stored directly in `browser_automations` (supports multiple intents as comma-separated)

5. **tool_usage** → **web_automations** (1:0..1)
   - One tool usage can result in one web automation
   - FK: `web_automations.tool_usage_id` → `tool_usage.tool_usage_id`
   - FK: `web_automations.message_id` → `chat_messages.message_id` (UNIQUE)
   - **Intent Classifier**: `classification_target = 'web_automation'`
   - **Domain**: Denormalized from `chat_messages.domain` (CRITICAL for Goal 2)
   - **Subdomain**: Calculated by intent classifier, stored directly in `web_automations` (supports multiple intents as comma-separated)

6. **chat_messages** → **usage_metrics** (1:N, optional)
   - One message can have multiple usage metric records (optional FK)
   - FK: `usage_metrics.message_id` → `chat_messages.message_id` (optional)
   - Many metrics can belong to one thread_id (many-to-one relationship)

### Reference Table:

7. **domain_classifications** (standalone reference table)
   - **NOT used for ETL classification** - reference/training examples only
   - Classification is done by intent classifier analyzing `user_query` (NOT via table lookup)
   - Stores example patterns and metadata for reference

---

## Key Design Features

### Distribution Keys (DISTKEY):
- All fact tables: **EVEN distribution** (no DISTKEY specified)
  - `thread_id` and `room_id` have low cardinality (many messages per thread/room), not suitable for distribution
- `domain_classifications`: `domain_name` as DISTKEY (reference table, small size)

### Sort Keys (SORTKEY):
- Time-series tables: `event_timestamp` as first sort key
- Composite sort keys for common query patterns:
  - `chat_messages`: `SORTKEY(event_timestamp, thread_id)`
  - `tool_usage`: `SORTKEY(event_timestamp, tool_type)`
  - `web_searches`: `SORTKEY(event_timestamp, search_type)`
  - `browser_automations`: `SORTKEY(event_timestamp, domain)`
  - `web_automations`: `SORTKEY(event_timestamp, domain)` (CRITICAL for Goal 2 analytics)
  - `usage_metrics`: `SORTKEY(event_timestamp, model, thread_id)`
  - `domain_classifications`: `SORTKEY(domain_category, intent_type, domain_name)`
  - `message_response_content`: `SORTKEY(message_id)`

### Intent Classifier Integration:
- **Source**: `tool_usage` table (all events stored here first) + `chat_messages.user_query`
- **Classification Basis**: Based on `response_body`, `step_type`, and `tool` fields from JSON
- **One Tool Per Message**: Classifier selects ONE tool per message (others discarded if multiple exist)
- **Multiple Subdomains Per Message**: ONE tool_type can have MULTIPLE intents in a single message (stored as comma-separated values in specialized tables)
- **Two-Stage Classification**:
  1. **Tool Routing**: Based on `tool_type` and `step_type` combination
     - `tool_type='web_search'` → `classification_target='web_search'` → `web_searches`
     - `tool_type='browser_tool_execution' AND step_type != 'ENTROPY_REQUEST'` → `classification_target='browser_automation'` → `browser_automations`
     - `tool_type='browser_tool_execution' AND step_type='ENTROPY_REQUEST'` → `classification_target='web_automation'` → `web_automations`
     - `tool_type='agent_progress' AND step_type='ENTROPY_REQUEST'` → `classification_target='web_automation'` → `web_automations`
     - `tool_type='agent_progress' AND step_type != 'ENTROPY_REQUEST'` → `classification_target='none'` → stays in `tool_usage` only
     - **Key Rule**: `step_type='ENTROPY_REQUEST'` always routes to `web_automations` (actual web action)
  2. **Domain/Subdomain Classification**: Based on `user_query` analysis
     - Intent classifier analyzes `user_query` from `request_body.messages[0].content`
     - Outputs `domain` (e.g., 'Transactional', 'Informational', 'Entertainment', 'Productivity')
     - Outputs `subdomain` (e.g., 'food_order,delivery' for multiple intents, 'shopping', 'booking' for single intent)
     - **Multiple Intents Support**: Can identify and store multiple subdomain intents as comma-separated values (e.g., 'food_order,delivery')
     - `domain` stored in `chat_messages.domain` (source of truth)
     - `subdomain` stored directly in specialized tables (`web_searches`, `browser_automations`, `web_automations`) - NOT in `chat_messages`
     - `domain` denormalized to specialized tables for analytics without JOINs
- **Tracking**: `classification_target` in `tool_usage`, `domain` in `chat_messages` and specialized tables, `subdomain` in specialized tables only

---

## Notes

1. **Foreign Key Constraints**: Redshift doesn't enforce FK constraints, but relationships are maintained logically through ETL

2. **Denormalization**: 
   - `domain` is stored in `chat_messages` (source of truth) and denormalized to specialized tables for better query performance (avoids JOINs)
   - `subdomain` is calculated by intent classifier and stored directly in specialized tables (NOT in `chat_messages`)

3. **ETL Workflow**: Intent classifier runs before table inserts, routing data to appropriate tables based on `response_body`, `step_type`, and `tool`

4. **Domain/Subdomain Classification**: Done by intent classifier analyzing `user_query` from `request_body`, NOT via table lookup

5. **One Tool Per Message**: Classifier selects ONE tool per message - if multiple tools exist in JSON, others are discarded

6. **Multiple Subdomains Per Message**: ONE tool_type can have MULTIPLE intents in a single message - stored as comma-separated values in `subdomain` field in specialized tables (e.g., 'food_order,delivery')

7. **Source of Truth**: 
   - `chat_messages.domain` is the source of truth for domain
   - `subdomain` is stored only in specialized tables (not in `chat_messages`)

8. **Large Content Separation**: `message_response_content` separated from `chat_messages` for performance (Redshift best practice)

9. **EVEN Distribution**: No DISTKEY specified (EVEN distribution) - `thread_id` and `room_id` have low cardinality, not suitable for distribution

10. **Relationship Fields**: `thread_id` and `room_id` are NOT unique identifiers of a message - they are relationship fields (many messages can belong to one thread/room)

11. **UNIQUE Constraints**: `message_id` has UNIQUE constraints in specialized tables (`web_searches`, `browser_automations`, `web_automations`) ensuring 1:1 relationships

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
-- Find all messages with "food_order" intent (including multi-intent)
SELECT * FROM web_automations
WHERE domain = 'Transactional' 
  AND subdomain LIKE '%food_order%';

-- Find all messages with both "food_order" AND "delivery"
SELECT * FROM web_automations
WHERE domain = 'Transactional'
  AND subdomain LIKE '%food_order%'
  AND subdomain LIKE '%delivery%';

-- Count messages by individual subdomain (requires parsing)
SELECT 
    COUNT(*) as total_messages,
    SUM(CASE WHEN subdomain LIKE '%food_order%' THEN 1 ELSE 0 END) as food_order_count,
    SUM(CASE WHEN subdomain LIKE '%delivery%' THEN 1 ELSE 0 END) as delivery_count,
    SUM(CASE WHEN subdomain LIKE '%shopping%' THEN 1 ELSE 0 END) as shopping_count,
    SUM(CASE WHEN subdomain LIKE '%booking%' THEN 1 ELSE 0 END) as booking_count
FROM web_automations
WHERE domain = 'Transactional';
```
