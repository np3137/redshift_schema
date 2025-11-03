# Task Completion Tracking Guide

## Overview

This document explains how to track and analyze task completion across the schema. Task completion can be tracked at multiple levels:
1. **Session Level**: Overall task completion status
2. **Response Level**: Response-specific task completion
3. **Action Level**: Individual web automation action completion

---

## Schema Fields for Task Completion

### 1. `chat_sessions` Table (Session-Level)

**Fields Added**:
- `task_completed` (BOOLEAN): Overall task completion status
- `task_completion_status` (VARCHAR): Detailed status
  - Values: 'completed', 'failed', 'partial', 'in_progress', 'cancelled'
- `task_completion_reason` (TEXT): Reason for completion/failure

**Purpose**: Track whether the user's overall request/task was successfully completed

**Data Source**:
```json
{
  "response_body": {
    "task_completed": true,           // → task_completed
    "task_status": "completed",       // → task_completion_status
    "task_completion_reason": "..."   // → task_completion_reason
  }
  // OR extract from reasoning_steps agent_progress
}
```

### 2. `web_automations` Table (Action-Level)

**Existing Field**:
- `task_status`: Individual action status ("Succeeded", "In Progress", "Failed")

**New Field Added**:
- `task_completed` (BOOLEAN): Whether this specific action completed successfully

**Purpose**: Track individual web automation action completion

**Data Source**:
```json
{
  "reasoning_steps": [{
    "agent_progress": {
      "thought": "Task Succeeded: First Brie cheese product added to cart."
      // Extract "Task Succeeded" → task_completed = true
      // Extract "Task Failed" → task_completed = false
    }
  }]
}
```

---

## ETL Requirements for Task Completion

### Session-Level (chat_sessions)

```python
def extract_task_completion(response_body):
    """
    Extract task completion status from response_body
    """
    task_completed = None
    task_completion_status = None
    task_completion_reason = None
    
    # Method 1: Direct field in response_body
    if 'task_completed' in response_body:
        task_completed = response_body['task_completed']
    
    if 'task_status' in response_body:
        task_completion_status = response_body['task_status']
    
    if 'task_completion_reason' in response_body:
        task_completion_reason = response_body['task_completion_reason']
    
    # Method 2: Extract from status field
    if not task_completed and 'status' in response_body:
        status = response_body['status']
        if status == 'COMPLETED':
            task_completed = True
            task_completion_status = 'completed'
        elif status in ['FAILED', 'ERROR']:
            task_completed = False
            task_completion_status = 'failed'
    
    # Method 3: Infer from reasoning_steps
    if task_completed is None:
        reasoning_steps = extract_reasoning_steps(response_body)
        task_statuses = []
        
        for step in reasoning_steps:
            if step.get('type') == 'agent_progress':
                thought = step.get('agent_progress', {}).get('thought', '')
                if 'Task Succeeded' in thought or 'Task completed' in thought:
                    task_statuses.append('succeeded')
                elif 'Task Failed' in thought or 'Task failed' in thought:
                    task_statuses.append('failed')
        
        # If all actions succeeded, task is completed
        if task_statuses:
            if all(s == 'succeeded' for s in task_statuses):
                task_completed = True
                task_completion_status = 'completed'
            elif any(s == 'failed' for s in task_statuses):
                task_completed = False
                task_completion_status = 'failed'
            else:
                task_completed = None
                task_completion_status = 'partial'
    
    return {
        'task_completed': task_completed,
        'task_completion_status': task_completion_status,
        'task_completion_reason': task_completion_reason
    }
```

### Action-Level (web_automations)

```python
def extract_action_task_completion(agent_progress_step):
    """
    Extract task completion for individual action
    """
    thought = agent_progress_step.get('agent_progress', {}).get('thought', '')
    task_status = agent_progress_step.get('agent_progress', {}).get('task_status')
    
    task_completed = None
    
    # Extract from thought
    if thought:
        if 'Task Succeeded' in thought or 'succeeded' in thought.lower():
            task_completed = True
            task_status = task_status or 'Succeeded'
        elif 'Task Failed' in thought or 'failed' in thought.lower():
            task_completed = False
            task_status = task_status or 'Failed'
        elif 'In Progress' in thought or 'in progress' in thought.lower():
            task_completed = None
            task_status = task_status or 'In Progress'
    
    return {
        'task_completed': task_completed,
        'task_status': task_status
    }
```

---

## Querying Task Completion

### Query 1: Overall Task Completion Rate

```sql
-- Calculate task completion rate
SELECT 
    COUNT(*) AS total_tasks,
    SUM(CASE WHEN task_completed = TRUE THEN 1 ELSE 0 END) AS completed_tasks,
    SUM(CASE WHEN task_completed = FALSE THEN 1 ELSE 0 END) AS failed_tasks,
    SUM(CASE WHEN task_completed IS NULL THEN 1 ELSE 0 END) AS in_progress_tasks,
    ROUND(
        100.0 * SUM(CASE WHEN task_completed = TRUE THEN 1 ELSE 0 END) / COUNT(*),
        2
    ) AS completion_rate_percent
FROM chat_sessions
WHERE task_completed IS NOT NULL;
```

### Query 2: Task Completion by Status

```sql
-- Task completion breakdown by status
SELECT 
    task_completion_status,
    COUNT(*) AS task_count,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS percentage
FROM chat_sessions
WHERE task_completion_status IS NOT NULL
GROUP BY task_completion_status
ORDER BY task_count DESC;
```

### Query 3: Task Completion by Domain

```sql
-- Task completion rate by domain category
SELECT 
    wa.domain_category,
    COUNT(DISTINCT cs.session_id) AS total_sessions,
    SUM(CASE WHEN cs.task_completed = TRUE THEN 1 ELSE 0 END) AS completed_sessions,
    ROUND(
        100.0 * SUM(CASE WHEN cs.task_completed = TRUE THEN 1 ELSE 0 END) / 
        COUNT(DISTINCT cs.session_id),
        2
    ) AS completion_rate_percent
FROM chat_sessions cs
INNER JOIN web_automations wa ON cs.session_id = wa.session_id
WHERE cs.task_completed IS NOT NULL
GROUP BY wa.domain_category
ORDER BY completion_rate_percent DESC;
```

### Query 4: Task Completion Trends Over Time

```sql
-- Task completion rate over time
SELECT 
    DATE(cs.event_timestamp) AS completion_date,
    COUNT(*) AS total_tasks,
    SUM(CASE WHEN cs.task_completed = TRUE THEN 1 ELSE 0 END) AS completed_tasks,
    ROUND(
        100.0 * SUM(CASE WHEN cs.task_completed = TRUE THEN 1 ELSE 0 END) / COUNT(*),
        2
    ) AS completion_rate_percent
FROM chat_sessions cs
WHERE cs.task_completed IS NOT NULL
GROUP BY DATE(cs.event_timestamp)
ORDER BY completion_date DESC;
```

### Query 5: Action-Level Task Completion

```sql
-- Individual action completion analysis
SELECT 
    wa.action_type,
    wa.domain_category,
    COUNT(*) AS total_actions,
    SUM(CASE WHEN wa.task_completed = TRUE THEN 1 ELSE 0 END) AS completed_actions,
    SUM(CASE WHEN wa.task_status = 'Succeeded' THEN 1 ELSE 0 END) AS succeeded_actions,
    SUM(CASE WHEN wa.task_status = 'Failed' THEN 1 ELSE 0 END) AS failed_actions,
    ROUND(
        100.0 * SUM(CASE WHEN wa.task_completed = TRUE THEN 1 ELSE 0 END) / COUNT(*),
        2
    ) AS action_completion_rate
FROM web_automations wa
WHERE wa.task_completed IS NOT NULL OR wa.task_status IS NOT NULL
GROUP BY wa.action_type, wa.domain_category
ORDER BY action_completion_rate DESC;
```

### Query 6: Task Completion with Failure Reasons

```sql
-- Analyze failure reasons
SELECT 
    task_completion_reason,
    COUNT(*) AS failure_count,
    COUNT(DISTINCT session_id) AS unique_sessions,
    COUNT(DISTINCT thread_id) AS unique_threads
FROM chat_sessions
WHERE task_completed = FALSE
    AND task_completion_reason IS NOT NULL
GROUP BY task_completion_reason
ORDER BY failure_count DESC;
```

---

## Materialized View for Task Completion Analytics

```sql
-- Materialized view for task completion statistics
CREATE MATERIALIZED VIEW mv_task_completion_stats
BACKUP NO
AUTO REFRESH YES
AS
SELECT 
    DATE(cs.event_timestamp) AS completion_date,
    cs.task_completion_status,
    wa.domain_category,
    COUNT(*) AS task_count,
    SUM(CASE WHEN cs.task_completed = TRUE THEN 1 ELSE 0 END) AS completed_count,
    SUM(CASE WHEN cs.task_completed = FALSE THEN 1 ELSE 0 END) AS failed_count,
    ROUND(
        100.0 * SUM(CASE WHEN cs.task_completed = TRUE THEN 1 ELSE 0 END) / COUNT(*),
        2
    ) AS completion_rate_percent
FROM chat_sessions cs
LEFT JOIN web_automations wa ON cs.session_id = wa.session_id
WHERE cs.task_completed IS NOT NULL
GROUP BY DATE(cs.event_timestamp), cs.task_completion_status, wa.domain_category;

COMMENT ON MATERIALIZED VIEW mv_task_completion_stats IS 'Task completion statistics by date, status, and domain';
```

---

## Common Use Cases

### Use Case 1: Overall Success Rate
```sql
SELECT 
    ROUND(100.0 * SUM(CASE WHEN task_completed = TRUE THEN 1 ELSE 0 END) / COUNT(*), 2) AS success_rate
FROM chat_sessions
WHERE task_completed IS NOT NULL;
```

### Use Case 2: Failed Tasks Analysis
```sql
SELECT 
    task_completion_reason,
    COUNT(*) AS count
FROM chat_sessions
WHERE task_completed = FALSE
GROUP BY task_completion_reason
ORDER BY count DESC;
```

### Use Case 3: Completion Rate by Action Type
```sql
SELECT 
    wa.action_type,
    COUNT(*) AS total,
    SUM(CASE WHEN wa.task_completed = TRUE THEN 1 ELSE 0 END) AS completed,
    ROUND(100.0 * SUM(CASE WHEN wa.task_completed = TRUE THEN 1 ELSE 0 END) / COUNT(*), 2) AS rate
FROM web_automations wa
WHERE wa.task_completed IS NOT NULL
GROUP BY wa.action_type;
```

---

## Data Source Mapping

### From Topic Message:

**Option 1: Direct field in response_body**
```json
{
  "response_body": {
    "task_completed": true,
    "task_status": "completed"
  }
}
```

**Option 2: From reasoning_steps**
```json
{
  "response_body": {
    "choices": [{
      "message": {
        "reasoning_steps": [{
          "agent_progress": {
            "thought": "Task Succeeded: Product added to cart"
          }
        }]
      }
    }]
  }
}
```

**Option 3: From status field**
```json
{
  "response_body": {
    "status": "COMPLETED"  // → task_completed = true
  }
}
```

---

## Summary

### Fields Added:
1. ✅ `chat_sessions.task_completed` - Overall task completion (BOOLEAN)
2. ✅ `chat_sessions.task_completion_status` - Detailed status
3. ✅ `chat_sessions.task_completion_reason` - Reason for completion/failure
4. ✅ `web_automations.task_completed` - Individual action completion (BOOLEAN)

### Queries Available:
- Overall completion rate
- Completion by domain
- Completion by action type
- Completion trends over time
- Failure reason analysis

### ETL Requirements:
- Extract from `response_body.task_completed` OR
- Extract from `response_body.status` OR
- Infer from `reasoning_steps[].agent_progress.thought`

---

## Next Steps

1. **Update ETL** to populate task completion fields
2. **Run validation queries** to verify data population
3. **Create materialized view** for fast analytics
4. **Monitor completion rates** in production
