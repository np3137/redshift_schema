# Entity-Relationship (ER) Diagram - Updated
## Redshift Chat Analytics Schema

This is an updated ER diagram showing the current schema structure with domain/subdomain classification.

---

## Mermaid ER Diagram

```mermaid
erDiagram
    chat_messages ||--|| message_response_content : "1:1"
    chat_messages ||--|| tool_usage : "1:1"
    tool_usage ||--o| web_searches : "routes_to"
    tool_usage ||--o| browser_automations : "routes_to"
    tool_usage ||--o| web_automations : "routes_to"
    chat_messages ||--o{ usage_metrics : "has"
    
    chat_messages {
        VARCHAR message_id PK
        VARCHAR thread_id
        TIMESTAMP event_timestamp
        VARCHAR user_query
        VARCHAR domain
        VARCHAR subdomain
        VARCHAR intent_type
        VARCHAR tool_type
    }
    
    message_response_content {
        VARCHAR message_id PK
        VARCHAR response_content
    }
    
    tool_usage {
        BIGINT tool_usage_id PK
        VARCHAR message_id UNIQUE
        VARCHAR tool_type
        VARCHAR step_type
        VARCHAR classification_target
    }
    
    web_searches {
        BIGINT search_id PK
        BIGINT tool_usage_id FK
        VARCHAR message_id UNIQUE
        VARCHAR domain
        VARCHAR subdomain
    }
    
    browser_automations {
        BIGINT browser_action_id PK
        BIGINT tool_usage_id FK
        VARCHAR message_id UNIQUE
        VARCHAR domain
        VARCHAR subdomain
    }
    
    web_automations {
        BIGINT web_action_id PK
        BIGINT tool_usage_id FK
        VARCHAR message_id UNIQUE
        VARCHAR domain
        VARCHAR subdomain
    }
    
    usage_metrics {
        BIGINT metric_id PK
        VARCHAR message_id FK
        INTEGER total_tokens
        DOUBLE total_cost
    }
    
    domain_classifications {
        VARCHAR domain_name PK
        VARCHAR domain_category
        VARCHAR subcategory
    }
```

---

## Relationship Summary

### Key Relationships:

1. **chat_messages** (1) → **tool_usage** (1) - One message = one tool
2. **chat_messages** (1) → **message_response_content** (1) - Large content separated
3. **tool_usage** (1) → **web_searches** (0..1) - Routes based on classification_target='web_search'
4. **tool_usage** (1) → **browser_automations** (0..1) - Routes based on classification_target='browser_automation'
5. **tool_usage** (1) → **web_automations** (0..1) - Routes based on classification_target='web_automation'
6. **chat_messages** (1) → **usage_metrics** (N) - Multiple metrics per message
7. **domain/subdomain** denormalized from chat_messages to specialized tables

The ER diagram has been updated in `ER_DIAGRAM.md` with the current schema structure including domain/subdomain fields.

