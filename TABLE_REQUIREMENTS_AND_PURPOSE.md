# Table Requirements and Purpose - Complete Guide

## Overview

This document explains the purpose, requirements, and data sources for each table in the Redshift schema for chat analytics.

---

## Core Tables (Base Schema)

### 1. `chat_sessions`

**Purpose**: Main session/thread level metadata and status tracking

**Business Goal**: Track chat sessions and their completion status for overall system monitoring

**What It Stores**:
- Session identifiers (session_id, thread_id, room_id)
- Timestamp information
- Model used
- Response reference
- Session status and type

**Data Source in Topic Message**:
```json
{
  // TOP-LEVEL → chat_sessions
  "_id": {"$oid": "..."},           // → session_id
  "room_id": "",                    // → room_id
  "thread_id": "...",               // → thread_id
  "@timestamp": 1761126835.345874,  // → event_timestamp
  "timestamp": {"$date": "..."},    // → created_timestamp
  "response_body": {
    "id": "...",                    // → response_id (FK only)
    // NOTE: model, status, type are in responses table (normalized)
  }
}
```

**Key Fields & Requirements**:
- `session_id` (REQUIRED): Unique identifier from `_id.$oid`
- `thread_id` (REQUIRED): Conversation thread identifier
- `event_timestamp` (REQUIRED): When the event occurred (`@timestamp`)
- `response_id`: Foreign key to `responses` table
- `task_completed`: Overall task completion status (derived)
- `task_completion_status`: Detailed completion status
- `task_completion_reason`: Reason for completion/failure

**Note**: `model`, `status`, `type` are now in `responses` table (normalized - best practice)

**ETL Requirements**:
- Extract `_id.$oid` → `session_id`
- Convert Unix timestamp to TIMESTAMP
- Extract response metadata

**Analytics Use Cases**:
- Count total sessions
- Track completion rates
- Model usage statistics
- Session duration analysis

**Relationships**:
- One-to-one with `responses` (via `response_id`)
- One-to-many with `tool_usage`, `usage_metrics`

---

### 2. `responses`

**Purpose**: Store AI response content separately (large TEXT field)

**Business Goal**: Efficiently store and query response content without impacting other queries

**What It Stores**:
- Response identifier
- Full response content (TEXT)
- Finish reason
- Model information

**Data Source in Topic Message**:
```json
{
  "response_body": {
    "id": "c798fc9a-e079-4429-bc71-62a6096c6b74",  // → response_id (PK)
    "created": 1761126835,                         // → created_timestamp
    "model": "sonar-pro",                          // → model
    "status": "COMPLETED",                         // → status (MOVED from chat_sessions)
    "type": "end_of_stream",                       // → type (MOVED from chat_sessions)
    "object": "chat.completion.done",             // → object (NEW)
    "choices": [{
      "finish_reason": "stop",                     // → finish_reason
      "message": {
        "content": "## 브리치즈가 장바구니에..."   // → response_content
      }
    }]
  }
}
```

**Key Fields & Requirements**:
- `response_id` (REQUIRED): Primary key, from `response_body.id`
- `session_id` (REQUIRED): Links to `chat_sessions`
- `response_content` (TEXT): Full AI response text
- `finish_reason`: How response ended ("stop", "length", etc.)
- `model` (REQUIRED): AI model used - from `response_body.model`
- `status` (REQUIRED): Response status - from `response_body.status` (MOVED from chat_sessions)
- `type` (REQUIRED): Response type - from `response_body.type` (MOVED from chat_sessions)
- `object`: Response object type - from `response_body.object` (NEW)
- `created_timestamp`: When response was created - from `response_body.created` (NEW)

**ETL Requirements**:
- Extract `response_body.id` → `response_id`
- Extract `choices[].message.content` → `response_content`
- Extract `choices[].finish_reason` → `finish_reason`

**Analytics Use Cases**:
- Response quality analysis
- Content length statistics
- Finish reason distribution
- Response content search (when needed)

**Relationships**:
- Referenced by `chat_sessions.response_id`
- Referenced by `user_feedback.response_id` (Phase 2)
- Referenced by `test_data_collection.response_id` (Phase 2)

**Design Rationale**: Separated because TEXT fields are large and should not be scanned unnecessarily in other queries.

---

### 3. `tool_usage`

**Purpose**: Track all tool/function calls made during chat sessions

**Business Goal**: 
- Goal 1: Basic statistical data (Search, Browser Automation, Web Automation counts)
- Goal 3: Usage metrics (how many times users utilize features)

**What It Stores**:
- Every tool call event
- Tool type classification
- Step information
- Reasoning thoughts

**Data Source in Topic Message**:
```json
{
  "response_body": {
    "choices": [{
      "message": {
        "reasoning_steps": [
          {
            "type": "web_search",              // → tool_type
            "thought": "...",                  // → thought
            "web_search": {...}                // → (goes to web_searches)
          },
          {
            "type": "browser_tool_execution",  // → tool_type
            "step_type": "ENTROPY_REQUEST",   // → step_type
            "browser_tool_execution": {...}    // → (goes to browser_automations)
          },
          {
            "type": "agent_progress",         // → tool_type
            "agent_progress": {
              "action": "click",              // → (goes to web_automations)
              "url": "..."
            }
          }
        ]
      }
    }]
  }
}
```

**Key Fields & Requirements**:
- `tool_usage_id` (AUTO): Primary key
- `session_id` (REQUIRED): Links to session
- `thread_id` (REQUIRED): Links to thread
- `event_timestamp` (REQUIRED): When tool was used
- `event_date` (REQUIRED): Populated in ETL as `DATE(event_timestamp)`
- `tool_type` (REQUIRED): "web_search", "browser_tool_execution", "agent_progress"
- `step_type`: Step type (e.g., "ENTROPY_REQUEST")
- `step_index`: Order in reasoning steps array
- `thought`: Reasoning thought text

**ETL Requirements**:
- **CRITICAL**: Populate `event_date = DATE(event_timestamp)`
- Extract from `reasoning_steps[]` array
- Extract `type` → `tool_type`
- Extract step-specific data to specialized tables

**Analytics Use Cases**:
- Count tool usage by type (Goal 1)
- Track tool usage frequency (Goal 3)
- Analyze tool usage patterns
- Identify most used tools

**Relationships**:
- One-to-many with `web_searches` (via `tool_usage_id`)
- One-to-many with `browser_automations` (via `tool_usage_id`)
- One-to-many with `web_automations` (via `tool_usage_id`)

**Design Rationale**: Central table for all tool usage tracking. Specialized tables store detailed information.

---

### 4. `web_searches`

**Purpose**: Track web search operations specifically

**Business Goal**: 
- Goal 1: Track search activity counts
- Goal 3: Track search usage metrics

**What It Stores**:
- Search operation details
- Search keywords
- Number of results
- Result count (pre-calculated)

**Data Source in Topic Message**:
```json
{
  "request_body": {
    "web_search_options": {
      "search_type": "auto"  // → search_type
    }
  },
  "response_body": {
    "choices": [{
      "message": {
        "reasoning_steps": [{
          "type": "web_search",
          "web_search": {
            "search_keywords": ["마켓컬리 브리치즈"],  // → search_keywords
            "search_results": [...]                    // → (goes to search_results)
          }
        }]
      }
    }]
  },
  "response_body": {
    "search_results": [...]  // → Also goes to search_results
  }
}
```

**Key Fields & Requirements**:
- `search_id` (AUTO): Primary key
- `tool_usage_id` (REQUIRED): Links to `tool_usage`
- `session_id` (REQUIRED): Links to session
- `event_timestamp` (REQUIRED): When search occurred
- `event_date` (REQUIRED): Populated in ETL as `DATE(event_timestamp)`
- `search_type`: Type of search ("auto", etc.)
- `search_keywords` (TEXT): Keywords searched (JSON array or comma-separated)
- `num_results`: Number of results returned
- `result_count` (REQUIRED): **CRITICAL** - Count of `search_results` for this search (populated in ETL)

**ETL Requirements**:
- **CRITICAL**: Populate `event_date = DATE(event_timestamp)`
- **CRITICAL**: Populate `result_count = COUNT(search_results WHERE search_id = this.search_id)`
- Extract from `reasoning_steps[].web_search`
- Extract keywords array → TEXT (JSON or comma-separated)

**Analytics Use Cases**:
- Search operation statistics
- Search keyword analysis
- Result count distribution
- Search type usage patterns

**Relationships**:
- Many-to-one with `tool_usage` (via `tool_usage_id`)
- One-to-many with `search_results` (via `search_id`)

**Design Rationale**: Specialized table for search operations to enable search-specific analytics without scanning all tool usage.

---

### 5. `search_results`

**Purpose**: Store individual search result details

**Business Goal**: Analyze search result quality and domain distribution

**What It Stores**:
- Individual search result information
- Result snippets and titles
- URLs and domains
- Domain categorization

**Data Source in Topic Message**:
```json
{
  "response_body": {
    "search_results": [
      {
        "snippet": "...",              // → snippet
        "source": "web",               // → source
        "title": "...",                // → title
        "url": "https://...",          // → url
        "date": "2025-10-01"           // → result_date
      },
      ...
    ]
  },
  "response_body": {
    "choices": [{
      "message": {
        "reasoning_steps": [{
          "web_search": {
            "search_results": [...]    // → Also here
          }
        }]
      }
    }]
  }
}
```

**Key Fields & Requirements**:
- `result_id` (AUTO): Primary key
- `search_id` (REQUIRED): Links to `web_searches`
- `session_id` (REQUIRED): Links to session
- `result_index`: Order in results array
- `snippet` (TEXT): Result snippet text
- `source`: Source type ("web", etc.)
- `title`: Result title
- `url`: Result URL
- `result_date`: Date from result (if available)
- `domain_name`: Extracted from URL in ETL
- `domain_category`: Classified from `domain_classifications`

**ETL Requirements**:
- Extract from both `response_body.search_results[]` and `reasoning_steps[].web_search.search_results[]`
- Extract domain from URL: `extract_domain_from_url(url)`
- Lookup `domain_category` from `domain_classifications` table
- Track result index for ordering

**Analytics Use Cases**:
- Search result quality metrics
- Domain distribution in results
- Result click-through analysis
- Search result freshness

**Relationships**:
- Many-to-one with `web_searches` (via `search_id`)
- Uses `domain_classifications` for categorization

**Design Rationale**: Separate table for detailed search results to avoid bloating `web_searches` table with array data.

---

### 6. `browser_automations`

**Purpose**: Track browser automation actions (non-web actions)

**Business Goal**: 
- Goal 1: Track browser automation activity counts
- Goal 2: Track what users are doing (searching history, grouping tabs, etc.)

**What It Stores**:
- Browser automation actions
- Action types and descriptions
- User and visitor IDs
- Step information

**Data Source in Topic Message**:
```json
{
  "response_body": {
    "choices": [{
      "message": {
        "reasoning_steps": [{
          "type": "browser_tool_execution",
          "browser_tool_execution": {
            "tool": {
              "step_type": "ENTROPY_REQUEST",  // → step_type
              "content": {
                "goal_id": "...",              // → goal_id
                "is_mission_control": false,   // → is_mission_control
                "visitor_id": "...",           // → visitor_id
                "user_id": "13702958"          // → user_id
              }
            }
          }
        }]
      }
    }]
  }
}
```

**Key Fields & Requirements**:
- `browser_action_id` (AUTO): Primary key
- `tool_usage_id` (REQUIRED): Links to `tool_usage`
- `session_id` (REQUIRED): Links to session
- `event_timestamp` (REQUIRED): When action occurred
- `action_type`: Type of browser action (extracted if available)
- `action_description` (TEXT): Description of action
- `step_type`: Step type (e.g., "ENTROPY_REQUEST")
- `goal_id`: Goal identifier
- `is_mission_control`: Boolean flag
- `visitor_id`: Visitor identifier
- `user_id`: User identifier

**ETL Requirements**:
- Extract from `reasoning_steps[].browser_tool_execution`
- Parse action type from tool execution data
- Extract user identifiers

**Analytics Use Cases**:
- Browser automation usage counts
- Action type distribution
- User engagement metrics
- Browser automation success rates

**Relationships**:
- Many-to-one with `tool_usage` (via `tool_usage_id`)

**Design Rationale**: Specialized table for browser automation to track actions like history searches, tab management, etc.

---

### 7. `web_automations`

**Purpose**: Track web automation actions (ENTROPY_REQUEST - actual web interactions)

**Business Goal**: 
- Goal 1: Track web automation activity counts
- Goal 2: Track what specific actions users are taking on the web (shopping on Amazon, booking trips, etc.)
- Goal 2: Domain categorization (Shopping, Booking, Entertainment, etc.)

**What It Stores**:
- Web action details (click, search, add_to_cart, etc.)
- Action URLs
- Domain categorization
- Task status

**Data Source in Topic Message**:
```json
{
  "response_body": {
    "choices": [{
      "message": {
        "reasoning_steps": [{
          "type": "agent_progress",
          "agent_progress": {
            "action": "click",                    // → action_type
            "url": "https://www.kurly.com/...",   // → action_url
            "thought": "I can see the search..."  // → thought
          }
        }]
      }
    }]
  }
}
```

**Key Fields & Requirements**:
- `web_action_id` (AUTO): Primary key
- `tool_usage_id` (REQUIRED): Links to `tool_usage`
- `session_id` (REQUIRED): Links to session
- `event_timestamp` (REQUIRED): When action occurred
- `event_date` (REQUIRED): Populated in ETL as `DATE(event_timestamp)`
- `action_type` (REQUIRED): Action type ("click", "search", "add_to_cart", etc.)
- `action_url`: URL where action occurred
- `thought` (TEXT): Reasoning thought
- `domain_category` (REQUIRED): **CRITICAL** - Must be populated from `domain_classifications` lookup
- `domain_name` (REQUIRED): Extracted from URL
- `task_status`: Status ("Succeeded", "In Progress", etc.)

**ETL Requirements**:
- **CRITICAL**: Populate `event_date = DATE(event_timestamp)`
- **CRITICAL**: Extract `domain_name` from URL
- **CRITICAL**: Lookup `domain_category` from `domain_classifications` table
- Extract from `reasoning_steps[].agent_progress`
- Extract action type from `agent_progress.action`
- Extract URL from `agent_progress.url`

**Analytics Use Cases**:
- Web automation action counts by type
- Domain usage analytics (Shopping, Booking, etc.)
- Action success rates
- Domain-based user behavior analysis

**Relationships**:
- Many-to-one with `tool_usage` (via `tool_usage_id`)
- Uses `domain_classifications` for categorization

**Design Rationale**: Most important table for Goal 2 - tracks actual user actions on websites with domain categorization.

---

### 8. `browser_history`

**Purpose**: Store browser history entries from user's browser

**Business Goal**: 
- Goal 2: Analyze user browsing patterns
- Context for understanding user behavior

**What It Stores**:
- Browser history entries
- Page visits and visit counts
- Domain categorization

**Data Source in Topic Message**:
```json
{
  "request_body": {
    "browser_history": [
      {
        "visit_count": 1,                      // → visit_count
        "title": "검색결과 > 치즈 - 마켓컬리",   // → page_title
        "url": "https://www.kurly.com/...",    // → page_url
        "last_visit_ts": 1761038382752.196     // → last_visit_ts
      },
      ...
    ]
  }
}
```

**Key Fields & Requirements**:
- `history_id` (AUTO): Primary key
- `session_id` (REQUIRED): Links to session
- `thread_id` (REQUIRED): Links to thread
- `event_timestamp` (REQUIRED): When history was captured
- `event_date` (REQUIRED): Populated in ETL as `DATE(event_timestamp)`
- `visit_count`: Number of times page visited
- `page_title`: Page title
- `page_url`: Page URL
- `last_visit_ts`: Unix timestamp of last visit
- `domain_name` (REQUIRED): Extracted from URL in ETL
- `domain_category`: Classified from `domain_classifications`

**ETL Requirements**:
- **CRITICAL**: Populate `event_date = DATE(event_timestamp)`
- **CRITICAL**: Extract `domain_name` from `page_url`
- Extract from `request_body.browser_history[]` array
- Lookup `domain_category` from `domain_classifications` (recommended)

**Analytics Use Cases**:
- User browsing pattern analysis
- Most visited domains
- Domain category distribution
- Visit frequency analysis

**Relationships**:
- Uses `domain_classifications` for categorization

**Design Rationale**: Stores user's browser context to understand behavior patterns and domain preferences.

---

### 9. `usage_metrics`

**Purpose**: Track token usage, costs, and latency

**Business Goal**: 
- Goal 3: Track usage metrics
- Cost analysis
- Performance monitoring

**What It Stores**:
- Token counts (prompt, completion, total)
- Cost breakdown (input, output, request, total)
- Latency metrics
- Model information

**Data Source in Topic Message**:
```json
{
  "response_body": {
    "usage": {
      "completion_tokens": 234,        // → completion_tokens
      "prompt_tokens": 18,             // → prompt_tokens
      "total_tokens": 252,             // → total_tokens
      "cost": {
        "input_tokens_cost": 0,        // → input_tokens_cost
        "output_tokens_cost": 0.004,   // → output_tokens_cost
        "request_cost": 0.006,         // → request_cost
        "total_cost": 0.01             // → total_cost
      },
      "search_context_size": "low"    // → search_context_size
    },
    "model": "sonar-pro",              // → model
    "created": 1761126835              // → event_timestamp
  }
}
```

**Key Fields & Requirements**:
- `metric_id` (AUTO): Primary key
- `session_id` (REQUIRED): Links to session
- `thread_id` (REQUIRED): Links to thread
- `event_timestamp` (REQUIRED): When usage occurred
- `event_date` (REQUIRED): Populated in ETL as `DATE(event_timestamp)`
- `completion_tokens`: Tokens in response
- `prompt_tokens`: Tokens in prompt
- `total_tokens`: Total tokens used
- `input_tokens_cost`: Cost of input tokens
- `output_tokens_cost`: Cost of output tokens
- `request_cost`: Base request cost
- `total_cost`: Total cost
- `search_context_size`: Context size ("low", "medium", "high")
- `latency_ms`: Latency in milliseconds (if available)
- `model`: AI model used

**ETL Requirements**:
- **CRITICAL**: Populate `event_date = DATE(event_timestamp)`
- Extract from `response_body.usage`
- Extract nested cost structure
- Calculate latency if available from system metrics

**Analytics Use Cases**:
- Cost analysis by model
- Token usage trends
- Latency monitoring
- Cost per session/thread analysis

**Relationships**:
- Referenced by `mv_user_usage_summary` (joined with tool_usage)

**Design Rationale**: Centralized cost and performance tracking for financial and operational analysis.

---

### 10. `domain_classifications`

**Purpose**: Reference/lookup table for domain categorization

**Business Goal**: 
- Goal 2: Domain categorization (Shopping, Booking, Entertainment, Work, Education, Finance)

**What It Stores**:
- Domain names
- Domain categories
- Subcategories
- Intent types

**Key Fields & Requirements**:
- `domain_name` (REQUIRED, PK): Domain name (e.g., "www.kurly.com")
- `domain_category` (REQUIRED): Category ("Shopping", "Booking", "Entertainment", "Work", "Education", "Finance")
- `subcategory`: Subcategory ("E-commerce", "Travel", "Media", etc.)
- `intent_type`: Intent ("Transactional", "Informational", "Social", "Entertainment", "Productivity")
- `is_active`: Whether classification is active

**Data Source**: 
- Manually populated/curated
- Not from topic messages

**ETL Requirements**:
- Populate during initial setup
- Update as new domains are discovered
- Maintain active/inactive status

**Analytics Use Cases**:
- Domain categorization lookup
- Category distribution analysis
- Intent type analysis

**Relationships**:
- Referenced by `web_automations`, `browser_history`, `search_results` for categorization

**Design Rationale**: Lookup table to avoid repeating category data and enable easy updates.

---

## Phase 2 Tables (Future Enhancements)

### 11. `user_feedback` (Goal 4)

**Purpose**: Store user likes/dislikes for system quality analysis

**Business Goal**: 
- Goal 4: System quality analysis via likes/dislikes

**Key Fields**:
- `feedback_id` (AUTO): Primary key
- `session_id` (REQUIRED): Links to session
- `user_id`: User identifier
- `feedback_type` (REQUIRED): "like", "dislike", "neutral"
- `response_id`: Links to specific response
- `feedback_timestamp`: When feedback was given

**ETL Requirements**:
- Extract from UI feedback events
- Link to `responses` table via `response_id`

**Analytics Use Cases**:
- Quality score calculation
- Feedback trend analysis
- Response quality correlation

---

### 12. `test_data_collection` (Goal 5)

**Purpose**: Store liked responses for training data

**Business Goal**: 
- Goal 5: Test data utilization for in-house solution

**Key Fields**:
- `test_data_id` (AUTO): Primary key
- `response_id` (REQUIRED): Links to response
- `response_content` (TEXT): Snapshot of response
- `reasoning_steps` (JSON): Snapshot of reasoning
- `feedback_id`: Links to user_feedback

**ETL Requirements**:
- Extract only "liked" responses
- Snapshot response content at feedback time
- Store reasoning steps as JSON

**Analytics Use Cases**:
- Training data collection
- Response quality patterns
- Model improvement analysis

---

### 13. `user_profiles` (Goal 6)

**Purpose**: Store user personalization data

**Business Goal**: 
- Goal 6: Long-term memory and personalization

**Key Fields**:
- `user_id` (REQUIRED, PK): User identifier
- `thread_id` (REQUIRED): Links to thread
- `profile_data` (JSON): Flexible profile attributes
- `preferences` (JSON): User preferences

**ETL Requirements**:
- Extract from user settings
- Store as flexible JSON structure

**Analytics Use Cases**:
- Personalization analysis
- User preference patterns
- Profile-based recommendations

---

### 14. `session_context` (Goal 6)

**Purpose**: Store context for AI agent long-term memory

**Business Goal**: 
- Goal 6: Context storage for personalization

**Key Fields**:
- `context_id` (AUTO): Primary key
- `session_id` (REQUIRED): Links to session
- `context_type`: "research", "conversation", "task"
- `context_data` (TEXT): Context content
- `expires_timestamp`: When context expires

**ETL Requirements**:
- Extract context from AI agent
- Store with expiration date

**Analytics Use Cases**:
- Context usage patterns
- Context effectiveness analysis

---

### 15. `bookmarks` (Goal 6)

**Purpose**: Store user bookmarks

**Business Goal**: 
- Goal 6: User bookmarks tracking

**Key Fields**:
- `bookmark_id` (AUTO): Primary key
- `thread_id` (REQUIRED): Links to thread
- `user_id`: User identifier
- `bookmark_title`: Bookmark title
- `bookmark_url`: Bookmark URL
- `bookmark_type`: "page", "search", "result"

**ETL Requirements**:
- Extract from bookmark events
- Link to thread/user

**Analytics Use Cases**:
- Bookmark usage patterns
- Most bookmarked domains

---

### 16. `tab_groups` (Goal 6)

**Purpose**: Track tab grouping/ungrouping actions

**Business Goal**: 
- Goal 2: Browser automation tracking (grouping tabs)

**Key Fields**:
- `group_id` (AUTO): Primary key
- `thread_id` (REQUIRED): Links to thread
- `group_name`: Group name
- `group_type`: "grouped", "ungrouped"
- `tab_urls` (JSON): Array of URLs in group

**ETL Requirements**:
- Extract from tab group events
- Store URLs as JSON array

**Analytics Use Cases**:
- Tab grouping patterns
- Group size analysis

---

### 17. `research_sessions` (Goal 6)

**Purpose**: Track research-specific sessions

**Business Goal**: 
- Goal 6: Research tracking

**Key Fields**:
- `research_id` (AUTO): Primary key
- `session_id` (REQUIRED): Links to session
- `research_topic` (TEXT): Research topic
- `research_keywords` (TEXT): Keywords used
- `citations` (JSON): Array of citations
- `freshness_score`: Information freshness score

**ETL Requirements**:
- Extract from research events
- Store citations as JSON

**Analytics Use Cases**:
- Research topic analysis
- Citation quality metrics

---

### 18. `interruptions` (Goal 6)

**Purpose**: Track interruptions in AI agent sessions

**Business Goal**: 
- Goal 6: Interruption tracking

**Key Fields**:
- `interruption_id` (AUTO): Primary key
- `session_id` (REQUIRED): Links to session
- `interruption_type`: "user_pause", "timeout", "error"
- `interruption_timestamp`: When interruption occurred
- `recovery_timestamp`: When recovered

**ETL Requirements**:
- Extract from system events
- Track interruption and recovery times

**Analytics Use Cases**:
- Interruption rate analysis
- Recovery time metrics
- Error pattern analysis

---

## Summary: Critical ETL Requirements

### Must Populate (Required):
1. ✅ `event_date = DATE(event_timestamp)` for:
   - `tool_usage`
   - `web_searches`
   - `web_automations`
   - `browser_history`
   - `usage_metrics`

2. ✅ `domain_category` from `domain_classifications` lookup for:
   - `web_automations` (REQUIRED)
   - `browser_history` (RECOMMENDED)

3. ✅ `domain_name` extracted from URLs for:
   - `web_automations`
   - `browser_history`
   - `search_results`

4. ✅ `result_count = COUNT(search_results)` for:
   - `web_searches`

### Data Extraction Sources:
- Top-level: `_id`, `thread_id`, `@timestamp`, `timestamp.$date`
- `request_body.browser_history[]`
- `response_body.search_results[]`
- `response_body.usage.*`
- `response_body.choices[].message.reasoning_steps[]`

---

## Table Relationships Summary

```
chat_sessions (1) ──┬──> responses (1:1 via response_id)
                    │
                    ├──> tool_usage (1:N via session_id)
                    │       ├──> web_searches (1:N via tool_usage_id)
                    │       │       └──> search_results (1:N via search_id)
                    │       ├──> browser_automations (1:N via tool_usage_id)
                    │       └──> web_automations (1:N via tool_usage_id)
                    │
                    └──> usage_metrics (1:N via session_id)

domain_classifications (lookup)
    └──> Referenced by: web_automations, browser_history, search_results
```

This completes the comprehensive explanation of all tables, their requirements, and purposes!

