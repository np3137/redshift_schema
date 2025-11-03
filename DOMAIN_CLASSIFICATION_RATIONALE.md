# Domain Classification Placement Rationale

## Current Design

Currently, `domain_category` is only stored in the `web_automations` table, even though:
- The `user_query` is stored at the `chat_sessions` level
- Domain classification is based on analyzing the user query (session-level concept)
- Other tables (`browser_automations`, `web_searches`, `tool_usage`) don't have domain classification

## Why This Design Might Be Problematic

### Issue 1: Domain Classification is Session-Level, Not Action-Level
- User query comes from `request_body` at the session level
- One user query should map to one domain category per session
- Having it only in `web_automations` means:
  - If a session has browser_automations but no web_automations, we lose domain classification
  - If a session has multiple web_automations, they all get the same classification (redundant)

### Issue 2: Analytics Limitations
- Can't analyze domain categories for browser_automations
- Can't analyze domain categories for web_searches
- Can't get overall session-level domain statistics without joining to web_automations

### Issue 3: Data Redundancy
- If one session has 10 web_automations, domain_category is stored 10 times (same value)

## Better Design Options

### Option 1: Move to chat_sessions (RECOMMENDED)
**Pros:**
- Domain classification is a session-level concept (one query = one classification)
- No redundancy (stored once per session)
- Available for all analytics queries
- Matches the data model (user_query is already there)

**Cons:**
- None significant

**Implementation:**
```sql
CREATE TABLE chat_sessions (
    ...
    user_query VARCHAR(2000),
    domain_category VARCHAR(50),  -- From intent classifier (based on user_query)
    intent_type VARCHAR(30),      -- From intent classifier
    classification_confidence DECIMAL(3,2),
    ...
);
```

### Option 2: Move to tool_usage (Alternative)
**Pros:**
- All tools relate to the same user query
- Can track classification for each tool event
- Still reduces redundancy compared to web_automations

**Cons:**
- Slightly more redundant than session level (if multiple tools per session)
- Domain classification is still session-level concept

### Option 3: Keep Current + Add to chat_sessions
**Pros:**
- Backward compatible
- Can still query web_automations directly
- Session-level analytics available

**Cons:**
- Some redundancy
- Need to maintain consistency

## Recommendation

**Move domain classification to `chat_sessions` table** because:

1. **Conceptual Alignment**: Domain classification is based on user_query, which is a session-level attribute
2. **Data Normalization**: Avoids storing the same classification multiple times
3. **Analytics Flexibility**: Can analyze domain categories for all session activities, not just web_automations
4. **Simpler Queries**: No need to join to web_automations to get session domain classification

### Implementation
- Add `domain_category`, `intent_type`, and `classification_confidence` to `chat_sessions`
- Remove from `web_automations` (or keep for denormalization if needed for specific queries)
- Update ETL to classify once per session and store in chat_sessions
- All other tables can JOIN to chat_sessions to get domain classification when needed

