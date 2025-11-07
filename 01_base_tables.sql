-- ============================================
-- Base Tables for Chat Analytics - Redshift Schema
-- ============================================
-- KEY RELATIONSHIPS:
-- - message_id: UNIQUE per message (PRIMARY KEY) - unique identifier of a message
-- - thread_id: NOT unique per message - many messages can belong to one thread (many-to-one relationship). NOT a unique identifier of a message
-- - room_id: NOT unique per message - many messages can belong to one room (many-to-one relationship). NOT a unique identifier of a message
-- - CLASSIFIER: Glue classifier selects ONE tool_type from reasoning_steps[] per message (others in JSON discarded)
-- - MULTIPLE SUBDOMAINS PER MESSAGE: ONE tool_type (e.g., web_automation) can have MULTIPLE subdomain intents 
--   in a single message - for example, domain="Transactional" with subdomain="food_order,delivery" (multiple 
--   intents comma-separated). Intent classifier identifies multiple intents from user_query (e.g., "order food 
--   and schedule delivery" → domain="Transactional", subdomain="food_order,delivery")
-- - CONSOLIDATED TABLE: tool_actions consolidates web_searches, browser_automations, and web_automations into 
--   a single unified table with tool_type as discriminator (simplifies schema while maintaining functionality)
-- REDSHIFT BEST PRACTICES:
-- - Base tables store raw fact data only (no aggregations)
-- - Materialized views handle all aggregations and analytics
-- - DISTKEY: None (EVEN distribution) - thread_id has low cardinality (many messages per thread), not suitable for distribution
-- - SORTKEY: event_timestamp first (time-series queries)
-- - Appropriate encoding for each column type

-- 1. chat_messages: Main message/request level data
CREATE TABLE chat_messages (
    message_id VARCHAR(128) NOT NULL PRIMARY KEY,  -- UNIQUE: From _id.$oid (if available) OR generated from response_id OR thread_id+@timestamp - unique per message
    room_id VARCHAR(128) NOT NULL ENCODE zstd,  -- From JSON room_id field - NOT unique per message, many messages can belong to one room (many-to-one relationship)
    thread_id VARCHAR(128) NOT NULL ENCODE zstd,  -- From JSON thread_id field - NOT unique per message, many messages can belong to one thread (many-to-one relationship). NOT a unique identifier of a message
    event_timestamp TIMESTAMP NOT NULL ENCODE delta32k,  -- From @timestamp (top-level)
    request_timestamp TIMESTAMP ENCODE delta32k,  -- From @timestamp - for latency calculation
    response_timestamp TIMESTAMP ENCODE delta32k,  -- From response_body.created (Unix timestamp) - for latency calculation
    tool_type VARCHAR(30) ENCODE bytedict,  -- Denormalized from tool_usage.classification_target - ONE tool per message: 'web_search', 'browser_automation', 'web_automation', or NULL if no tool used
    user_query VARCHAR(2000) ENCODE zstd,  -- From request_body.messages[0].content - input for intent classifier
    domain VARCHAR(50) ENCODE bytedict,  -- From intent classifier analyzing user_query - top-level domain (e.g., 'Transactional', 'Informational', 'Entertainment', 'Productivity') - SOURCE OF TRUTH. For web_automation tool_type: typically 'Transactional' with multiple subdomain intents
    subdomain VARCHAR(200) ENCODE zstd,  -- From intent classifier analyzing user_query - specific intent subdomain(s) under domain. Can contain MULTIPLE intents as comma-separated values (e.g., 'food_order,delivery' or 'shopping' or 'booking,food_order' under 'Transactional' for web_automation). ONE tool_type can have MULTIPLE intents per message - all stored in this field. SOURCE OF TRUTH. Example: 'food_order,delivery' for a message that involves both food ordering and delivery
    task_completed BOOLEAN ENCODE runlength,  -- Boolean benefits from runlength encoding
    task_completion_status VARCHAR(20) ENCODE bytedict,  -- Low cardinality: 'completed', 'failed', 'partial', 'in_progress', 'cancelled'
    -- Response metadata fields (frequently used in analytics)
    finish_reason VARCHAR(20) ENCODE bytedict,  -- From response_body.choices[0].finish_reason - low cardinality: 'stop', 'length', 'content_filter', etc.
    model VARCHAR(64) ENCODE bytedict,  -- From response_body.model - limited model names, low cardinality
    response_type VARCHAR(30) ENCODE bytedict,  -- From response_body.type - low cardinality: 'end_of_stream', etc.
    
    SORTKEY(event_timestamp, thread_id)
)
ENCODE AUTO;

-- 2. tool_usage: Individual tool call records (all types)
-- Central fact table for all tool usage events
-- CLASSIFIER: Glue classifier selects ONE tool from multiple reasoning_steps[] per message
CREATE TABLE tool_usage (
    tool_usage_id BIGINT IDENTITY(1,1),  -- PRIMARY KEY: Unique per tool call event
    message_id VARCHAR(128) NOT NULL UNIQUE ENCODE zstd,  -- FK to chat_messages.message_id - 1:1 relationship (one message = one tool selected by classifier)
    event_timestamp TIMESTAMP NOT NULL ENCODE delta32k,  -- From @timestamp
    tool_type VARCHAR(30) NOT NULL ENCODE bytedict,  -- From Glue classifier selection - ONE tool chosen from reasoning_steps[] - low cardinality: 'web_search', 'browser_tool_execution', 'agent_progress'
    step_type VARCHAR(50) ENCODE bytedict,  -- From selected reasoning step - low cardinality: 'ENTROPY_REQUEST', 'SEARCH_BROWSER', etc.
    classification_target VARCHAR(30) ENCODE bytedict,  -- Glue classifier routing output - 'browser_automation', 'web_automation', 'web_search', 'none'
    
    SORTKEY(event_timestamp, tool_type)
)
ENCODE AUTO;

-- 3. tool_actions: Consolidated table for all tool actions (web_search, browser_automation, web_automation)
-- Unified fact table for all tool-specific actions - consolidates web_searches, browser_automations, and web_automations
CREATE TABLE tool_actions (
    action_id BIGINT IDENTITY(1,1),  -- PRIMARY KEY: Unique per tool action event
    tool_usage_id BIGINT NOT NULL ENCODE delta,  -- FK to tool_usage.tool_usage_id
    message_id VARCHAR(128) NOT NULL UNIQUE ENCODE zstd,  -- FK to chat_messages.message_id - 1:1 relationship (UNIQUE: one message = one tool action)
    event_timestamp TIMESTAMP NOT NULL ENCODE delta32k,  -- From @timestamp
    tool_type VARCHAR(30) NOT NULL ENCODE bytedict,  -- Discriminator: 'web_search', 'browser_automation', 'web_automation' - determines which fields are populated
    domain VARCHAR(50) ENCODE bytedict,  -- Denormalized from chat_messages.domain - from intent classifier analyzing user_query (e.g., 'Transactional', 'Informational') - for analytics without JOINs. NOT NULL for web_automation (CRITICAL for Goal 2)
    subdomain VARCHAR(200) ENCODE zstd,  -- Denormalized from chat_messages.subdomain - from intent classifier analyzing user_query - can contain MULTIPLE intents as comma-separated values (e.g., 'food_order,delivery', 'shopping', 'booking,food_order' for web_automation with domain='Transactional') - ONE tool_type can have MULTIPLE intents per message - for analytics without JOINs
    
    SORTKEY(event_timestamp, tool_type, domain)
)
ENCODE AUTO;

-- 4. usage_metrics: Token usage, cost, latency metrics
-- Fact table for usage and cost metrics
CREATE TABLE usage_metrics (
    metric_id BIGINT IDENTITY(1,1),  -- PRIMARY KEY: Unique per usage metric event
    message_id VARCHAR(128) ENCODE zstd,  -- FK to chat_messages.message_id - optional, for traceability
    thread_id VARCHAR(128) NOT NULL ENCODE zstd,  -- From JSON thread_id field - NOT unique per message, many messages can belong to one thread (many-to-one relationship). NOT a unique identifier of a message
    event_timestamp TIMESTAMP NOT NULL ENCODE delta32k,  -- From @timestamp
    request_timestamp TIMESTAMP ENCODE delta32k,  -- From @timestamp - for latency calculation
    response_timestamp TIMESTAMP ENCODE delta32k,  -- From response_body.created (Unix timestamp) - for latency calculation
    completion_tokens INTEGER ENCODE delta,  -- From response_body.usage.completion_tokens - raw fact data
    prompt_tokens INTEGER ENCODE delta,  -- From response_body.usage.prompt_tokens - raw fact data
    total_tokens INTEGER ENCODE delta,  -- From response_body.usage.total_tokens - raw fact data
    input_tokens_cost DOUBLE PRECISION ENCODE delta32k,  -- From response_body.usage.cost.input_tokens_cost - raw fact data
    output_tokens_cost DOUBLE PRECISION ENCODE delta32k,  -- From response_body.usage.cost.output_tokens_cost - raw fact data
    request_cost DOUBLE PRECISION ENCODE delta32k,  -- From response_body.usage.cost.request_cost - raw fact data
    total_cost DOUBLE PRECISION ENCODE delta32k,  -- From response_body.usage.cost.total_cost - raw fact data
    search_context_size VARCHAR(10) ENCODE bytedict,  -- From response_body.usage.search_context_size - low cardinality: 'low', 'medium', 'high'
    latency_ms INTEGER ENCODE delta,  -- Pre-calculated latency (can be validated against timestamps) - raw fact data
    
    SORTKEY(event_timestamp, model, thread_id)
)
ENCODE AUTO;

-- 5. message_response_content: Large response content storage (separate table for rarely accessed content)
CREATE TABLE message_response_content (
    message_id VARCHAR(128) NOT NULL PRIMARY KEY,  -- FK to chat_messages.message_id - 1:1 relationship
    response_content VARCHAR(65535) ENCODE zstd,  -- From response_body.choices[0].message.content - large TEXT field (up to 65KB)
    insert_timestamp TIMESTAMP DEFAULT GETDATE() ENCODE delta32k,
    
    SORTKEY(message_id)
)
ENCODE AUTO;

-- ============================================
-- SCHEMA SUMMARY
-- ============================================
-- Total Tables: 5
-- 1. chat_messages - Core message fact table (source of truth for domain/subdomain)
-- 2. tool_usage - Tool usage events (1:1 with chat_messages)
-- 3. tool_actions - Consolidated tool actions (web_search, browser_automation, web_automation)
-- 4. usage_metrics - Token usage, cost, and latency metrics
-- 5. message_response_content - Large response content (separated for performance)
--
-- KEY DESIGN DECISIONS:
-- - Consolidated tool_actions table simplifies schema while maintaining functionality
-- - Domain/subdomain stored in chat_messages (source of truth) and denormalized to tool_actions
-- - Multiple subdomains per message supported via comma-separated values
-- - One tool_type per message (others discarded if multiple exist)
-- - Large content separated for query performance optimization

