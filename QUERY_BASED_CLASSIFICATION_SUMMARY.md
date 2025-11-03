# Query-Based Domain Classification Summary

## Key Principle

**Domain classification is performed by analyzing the `user_query` from `request_body`, NOT by looking up the `domain_classifications` table.**

---

## Classification Flow

```
┌─────────────────────────────────────────────────────┐
│  1. Extract user_query from request_body              │
│     (Stored in chat_sessions.user_query)             │
└─────────────────────────────────────────────────────┘
                    ↓
┌─────────────────────────────────────────────────────┐
│  2. Intent Classifier analyzes user_query text      │
│     - Understands user intent                        │
│     - Determines domain category                    │
│     - May reference domain_classifications for       │
│       patterns/examples (training reference only)    │
└─────────────────────────────────────────────────────┘
                    ↓
┌─────────────────────────────────────────────────────┐
│  3. Classifier outputs domain_category              │
│     (e.g., 'Shopping', 'Booking', 'Work')          │
└─────────────────────────────────────────────────────┘
                    ↓
┌─────────────────────────────────────────────────────┐
│  4. Store in web_automations.domain_category       │
│     (Denormalized for query performance)            │
└─────────────────────────────────────────────────────┘
```

---

## Table Roles

### `chat_sessions.user_query`
- **Source**: Extracted from `request_body`
- **Purpose**: Input to intent classifier
- **Storage**: VARCHAR(2000)

### `domain_classifications` Table
- **Role**: Reference/training table ONLY
- **NOT used for**: Lookup during classification
- **Used for**: 
  - Intent classifier training
  - Example query patterns
  - Category definitions/metadata
  - Reference documentation

### `web_automations.domain_category`
- **Role**: Intent classifier output (denormalized)
- **Source**: Direct output from intent classifier analyzing user_query
- **NOT from**: domain_classifications table lookup
- **Purpose**: Fast analytics queries without JOINs

---

## Example

### Input
```json
{
  "request_body": {
    "query": "Buy groceries on kurly.com"
  }
}
```

### Process
1. Extract: `user_query = "Buy groceries on kurly.com"`
2. Intent Classifier analyzes: Understands intent = Shopping/Transactional
3. Output: `domain_category = 'Shopping'`
4. Store: `web_automations.domain_category = 'Shopping'`

**No lookup in domain_classifications table needed!**

---

## Why Both Tables Exist?

| Table | Purpose | When Used |
|-------|---------|-----------|
| `domain_classifications` | Reference/training data | Intent classifier training, examples, metadata |
| `web_automations.domain_category` | Classifier output (denormalized) | Direct querying, analytics, sort keys |

**The classification is query-based analysis, not table lookup!**

---

## Best Practice

✅ **Correct**: Intent classifier analyzes `user_query` → outputs `domain_category` → stores in `web_automations.domain_category`

❌ **Wrong**: Lookup `domain_classifications` table based on URL → store FK or category name

---

## Summary

- Domain classification = **User query analysis** (not table lookup)
- `domain_classifications` = Reference/training table (not lookup table)
- `web_automations.domain_category` = Classifier output (denormalized for performance)

The design follows Redshift best practices: analyze once during ETL, store result denormalized for fast queries.

