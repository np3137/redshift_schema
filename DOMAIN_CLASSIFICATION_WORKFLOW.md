# Domain Classification Workflow
## Based on User Query Analysis

## Overview

Domain classification in this schema is **not** based on URL extraction. Instead, it's determined by analyzing the **user query** from `request_body` using an **Intent Classifier**.

The intent classifier processes the user's query to understand their intent and assigns appropriate domain categories for analytics.

---

## Classification Process

### Input: User Query from request_body

The user query is extracted from the `request_body` in the topic message:

```python
# Example request_body structure
request_body = {
    "query": "Buy groceries on kurly.com",
    "message": "Search for React documentation",
    "content": "...",
    # ... other fields
}

# Extract user query (try multiple fields)
user_query = request_body.get('query') or \
             request_body.get('message') or \
             request_body.get('content') or \
             request_body.get('user_input')
```

### Processing: Intent Classifier Analysis

The intent classifier analyzes the user query to determine:

1. **Domain Category**: Shopping, Booking, Entertainment, Work, Education, Finance
2. **Intent Type**: Transactional, Informational, Social, Entertainment, Productivity
3. **Subcategory**: E-commerce, Travel, Media, Developer Tools, Banking, etc.
4. **Confidence Score**: 0.00-1.00

```python
def classify_domain_from_query(user_query):
    """
    Intent classifier analyzes user query to determine domain category.
    
    Args:
        user_query: User's query text from request_body
    
    Returns:
        {
            'domain_category': 'Shopping',
            'intent_type': 'Transactional',
            'subcategory': 'E-commerce',
            'confidence': 0.95
        }
    """
    # Intent classifier processes the query
    classification = intent_classifier.analyze(user_query)
    
    return classification
```

### Output: Domain Category Assignment

The classified domain category is then stored in `web_automations.domain_category`:

```sql
INSERT INTO web_automations (
    ...
    domain_category,  -- From intent classifier (e.g., 'Shopping')
    domain_name,       -- Extracted from URL (separate from domain_category)
    classification_confidence  -- Confidence from intent classifier
)
VALUES (
    ...
    'Shopping',  -- From user query analysis, NOT from URL
    'www.kurly.com',  -- Extracted from action_url
    0.95  -- Confidence score
);
```

---

## Classification Examples

### Example 1: Shopping Intent

```python
# User Query
user_query = "Buy groceries on kurly.com"

# Intent Classifier Analysis
classification = intent_classifier.analyze(user_query)
# Returns:
# {
#     'domain_category': 'Shopping',
#     'intent_type': 'Transactional',
#     'subcategory': 'E-commerce',
#     'confidence': 0.92
# }

# Stored in web_automations
domain_category = 'Shopping'  # From query analysis
domain_name = 'kurly.com'  # From URL extraction
```

### Example 2: Booking Intent

```python
# User Query
user_query = "Book a flight to Seoul"

# Intent Classifier Analysis
classification = intent_classifier.analyze(user_query)
# Returns:
# {
#     'domain_category': 'Booking',
#     'intent_type': 'Transactional',
#     'subcategory': 'Travel',
#     'confidence': 0.88
# }

# Stored in web_automations
domain_category = 'Booking'  # From query analysis
domain_name = 'trip.com'  # From URL extraction (if action_url exists)
```

### Example 3: Work/Informational Intent

```python
# User Query
user_query = "Search for React documentation"

# Intent Classifier Analysis
classification = intent_classifier.analyze(user_query)
# Returns:
# {
#     'domain_category': 'Work',
#     'intent_type': 'Informational',
#     'subcategory': 'Developer Tools',
#     'confidence': 0.90
# }

# Stored in web_automations
domain_category = 'Work'  # From query analysis
domain_name = 'react.dev'  # From URL extraction
```

### Example 4: Entertainment Intent

```python
# User Query
user_query = "Watch YouTube video about cooking"

# Intent Classifier Analysis
classification = intent_classifier.analyze(user_query)
# Returns:
# {
#     'domain_category': 'Entertainment',
#     'intent_type': 'Entertainment',
#     'subcategory': 'Media',
#     'confidence': 0.85
# }

# Stored in web_automations
domain_category = 'Entertainment'  # From query analysis
domain_name = 'youtube.com'  # From URL extraction
```

---

## Domain Categories

The intent classifier maps user queries to these domain categories:

| Domain Category | Intent Types | Example Queries |
|----------------|--------------|----------------|
| **Shopping** | Transactional | "Buy groceries", "Purchase items", "Add to cart" |
| **Booking** | Transactional | "Book flight", "Reserve hotel", "Schedule appointment" |
| **Entertainment** | Entertainment | "Watch video", "Play music", "Stream movie" |
| **Work** | Informational, Productivity | "Search documentation", "Create presentation", "Check email" |
| **Education** | Informational | "Learn programming", "Study course", "Read tutorial" |
| **Finance** | Transactional, Informational | "Check balance", "Transfer money", "View statement" |

---

## ETL Integration

### Step-by-Step Process

```python
def process_web_automation_with_domain_classification(message_data):
    """
    Complete process for web_automation with domain classification.
    """
    session_id = message_data['_id']['$oid']
    
    # Step 1: Extract user query from request_body
    user_query = extract_user_query(message_data)
    
    # Step 2: Intent classifier analyzes user query
    domain_classification = intent_classifier.classify_domain_from_query(user_query)
    
    # Result:
    # {
    #     'domain_category': 'Shopping',
    #     'intent_type': 'Transactional',
    #     'subcategory': 'E-commerce',
    #     'confidence': 0.92
    # }
    
    # Step 3: Extract domain from URL (separate from classification)
    action_url = extract_action_url(message_data)
    domain_name = extract_domain_from_url(action_url)  # e.g., 'kurly.com'
    
    # Step 4: Insert into web_automations
    insert_into_web_automations({
        'tool_usage_id': tool_usage_id,
        'session_id': session_id,
        'action_url': action_url,
        'domain_category': domain_classification['domain_category'],  # From query analysis
        'domain_name': domain_name,  # From URL extraction
        'classification_confidence': domain_classification['confidence'],
        # ... other fields
    })
```

---

## domain_classifications Table Usage

The `domain_classifications` table serves as a **reference/mapping table** for the intent classifier:

### Purpose:
1. **Training Data**: Stores example query patterns and their mappings
2. **Reference**: Provides examples of category assignments
3. **Validation**: Can be used to validate classifier output
4. **Lookup (Optional)**: May be used for fallback if classifier confidence is low

### Structure:
```sql
CREATE TABLE domain_classifications (
    domain_name VARCHAR(255),  -- Can be 'N/A' for query-only classifications
    domain_category VARCHAR(50),  -- Shopping, Booking, etc.
    subcategory VARCHAR(50),
    intent_type VARCHAR(30),
    query_patterns VARCHAR(500),  -- Example queries that map to this category
    is_active BOOLEAN
);
```

### Example Data:
```sql
INSERT INTO domain_classifications VALUES
('N/A', 'Shopping', 'E-commerce', 'Transactional', 'Buy groceries, Purchase items, Add to cart', TRUE),
('N/A', 'Booking', 'Travel', 'Transactional', 'Book flight, Reserve hotel, Schedule appointment', TRUE),
('N/A', 'Work', 'Developer Tools', 'Informational', 'Search documentation, Find API reference', TRUE);
```

**Note**: The actual classification is performed by the intent classifier analyzing the user query, NOT by looking up this table. This table is for reference and training purposes.

---

## Key Differences from URL-Based Classification

| Aspect | URL-Based (Old) | Query-Based (Current) |
|--------|----------------|----------------------|
| **Input** | Extract domain from URL | Analyze user query text |
| **Process** | Lookup in domain_classifications table | Intent classifier ML/NLP analysis |
| **Output** | Static category from lookup | Dynamic category from query understanding |
| **Flexibility** | Limited to known domains | Can handle new queries and intents |
| **Accuracy** | Depends on domain list completeness | Depends on classifier training |

---

## Benefits

1. **Intent Understanding**: Classifies based on user intent, not just domain name
2. **Context Awareness**: Understands what the user wants to do, not just where they're going
3. **New Query Handling**: Can classify new queries that weren't in the training data
4. **Better Analytics**: More meaningful categories based on user behavior and intent
5. **Flexibility**: Can adapt to new domains and query patterns

---

## Implementation Notes

1. **Intent Classifier**: Should be a trained ML/NLP model (e.g., BERT, GPT-based, or custom)
2. **Query Extraction**: Ensure reliable extraction of user query from `request_body`
3. **Confidence Threshold**: Set minimum confidence threshold (e.g., 0.7) for reliable classifications
4. **Fallback Strategy**: If confidence is low, use 'Unknown' category
5. **Monitoring**: Track classification confidence scores to improve classifier over time

---

## Summary

- ✅ **Domain classification is based on user query analysis**, not URL extraction
- ✅ **Intent classifier processes user_query** from `request_body`
- ✅ **domain_category in web_automations** comes from intent classifier output
- ✅ **domain_classifications table** is for reference/training, not direct lookup
- ✅ **Better intent understanding** leads to more accurate analytics categories

