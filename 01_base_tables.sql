-- ============================================
-- Base Tables for Chat Analytics - Redshift Schema
-- ============================================
-- KEY RELATIONSHIPS:
-- - message_id: UNIQUE per message (PRIMARY KEY)
-- - thread_id: NOT unique - many messages can belong to one thread (many-to-one)
-- - CLASSIFIER: Glue classifier selects ONE tool from reasoning_steps[] per message
-- REDSHIFT BEST PRACTICES:
-- - Base tables store raw fact data only (no aggregations)
-- - Materialized views handle all aggregations and analytics
-- - DISTKEY: None (EVEN distribution) - thread_id has low cardinality (many messages per thread), not suitable for distribution
-- - SORTKEY: event_timestamp first (time-series queries)
-- - Appropriate encoding for each column type

-- 1. chat_messages: Main message/request level data
-- Core fact table for individual chat messages
-- RELATIONSHIP: Many messages can belong to one thread_id (many-to-one)
CREATE TABLE chat_messages (
    message_id VARCHAR(128) NOT NULL PRIMARY KEY,  -- UNIQUE: From _id.$oid (if available) OR generated from response_id OR thread_id+@timestamp - unique per message
    thread_id VARCHAR(128) NOT NULL ENCODE zstd,  -- From JSON thread_id field (top-level or request_body.thread_id) - NOT unique, many messages per thread
    event_timestamp TIMESTAMP NOT NULL ENCODE delta32k,  -- From @timestamp (top-level)
    request_timestamp TIMESTAMP ENCODE delta32k,  -- From @timestamp - for latency calculation
    response_timestamp TIMESTAMP ENCODE delta32k,  -- From response_body.created (Unix timestamp) - for latency calculation
    created_timestamp TIMESTAMP ENCODE delta32k,  -- From response_body.created (Unix timestamp)
    response_id VARCHAR(128) ENCODE zstd,  -- From response_body.id - unique per message
    user_query VARCHAR(2000) ENCODE zstd,  -- From request_body.messages[0].content - input for intent classifier
    domain_category VARCHAR(50) ENCODE bytedict,  -- From intent classifier analyzing user_query (Shopping, Booking, Entertainment, Work, Education, Finance) - SOURCE OF TRUTH
    intent_type VARCHAR(30) ENCODE bytedict,  -- From intent classifier (Transactional, Informational, Social, Entertainment, Productivity)
    classification_confidence DECIMAL(3,2) ENCODE delta32k,  -- Intent classifier confidence score (0.00-1.00)
    task_completed BOOLEAN ENCODE runlength,  -- Boolean benefits from runlength encoding
    task_completion_status VARCHAR(20) ENCODE bytedict,  -- Low cardinality: 'completed', 'failed', 'partial', 'in_progress', 'cancelled'
    task_completion_reason VARCHAR(500) ENCODE zstd,
    -- Response metadata fields (frequently used in analytics)
    finish_reason VARCHAR(20) ENCODE bytedict,  -- From response_body.choices[0].finish_reason - low cardinality: 'stop', 'length', 'content_filter', etc.
    model VARCHAR(64) ENCODE bytedict,  -- From response_body.model - limited model names, low cardinality
    response_type VARCHAR(30) ENCODE bytedict,  -- From response_body.type - low cardinality: 'end_of_stream', etc.
    insert_timestamp TIMESTAMP DEFAULT GETDATE() ENCODE delta32k,
    
    SORTKEY(event_timestamp, thread_id)
)
ENCODE AUTO;

COMMENT ON TABLE chat_messages IS 'Main message/request level data. Core fact table storing raw message and response metadata. UNIQUENESS: message_id is PRIMARY KEY (unique per message). RELATIONSHIP: Many messages can belong to one thread_id (many-to-one). IMPORTANT: If _id.$oid not in JSON, generate message_id from response_id OR thread_id+@timestamp. DOMAIN CLASSIFICATION: domain_category (source of truth) from intent classifier analyzing user_query. RESPONSE FIELDS: finish_reason, model, response_type stored here (frequently used in analytics). Large response_content moved to message_response_content table (separate table for rarely accessed large content). LATENCY: request_timestamp and response_timestamp enable latency calculation. TASK STATUS: task_completion_status tracks message-level task status. ANALYTICS: Use materialized views for aggregations (daily stats, domain analytics, etc.). DISTKEY: None (EVEN distribution - thread_id not suitable due to low cardinality). SORTKEY: event_timestamp first (time-series queries)';

-- 2. tool_usage: Individual tool call records (all types)
-- Central fact table for all tool usage events
-- CLASSIFIER: Glue classifier selects ONE tool from multiple reasoning_steps[] per message
CREATE TABLE tool_usage (
    tool_usage_id BIGINT IDENTITY(1,1),  -- PRIMARY KEY: Unique per tool call event
    message_id VARCHAR(128) NOT NULL UNIQUE ENCODE zstd,  -- FK to chat_messages.message_id - 1:1 relationship (one message = one tool selected by classifier)
    thread_id VARCHAR(128) NOT NULL ENCODE zstd,  -- From JSON thread_id field - NOT unique, many messages per thread
    event_timestamp TIMESTAMP NOT NULL ENCODE delta32k,  -- From @timestamp
    tool_type VARCHAR(30) NOT NULL ENCODE bytedict,  -- From Glue classifier selection - ONE tool chosen from reasoning_steps[] - low cardinality: 'web_search', 'browser_tool_execution', 'agent_progress'
    step_type VARCHAR(50) ENCODE bytedict,  -- From selected reasoning step - low cardinality: 'ENTROPY_REQUEST', 'SEARCH_BROWSER', etc.
    classification_target VARCHAR(30) ENCODE bytedict,  -- Glue classifier routing output - 'browser_automation', 'web_automation', 'web_search', 'none'
    insert_timestamp TIMESTAMP DEFAULT GETDATE() ENCODE delta32k,
    
    SORTKEY(event_timestamp, tool_type, thread_id)
)
ENCODE AUTO;

COMMENT ON TABLE tool_usage IS 'Central fact table for all tool usage events from response_body.reasoning_steps[]. RELATIONSHIP: 1:1 with chat_messages.message_id (one message = one tool selected by classifier). CLASSIFIER: Glue classifier analyzes reasoning_steps[] array and selects ONE tool based on priority (ENTROPY_REQUEST actions take precedence). If multiple tools exist (e.g., web_search + browser_tool_execution), classifier chooses the PRIMARY one. ROUTING: tool_type and step_type determine classification_target and routing to specialized tables. ANALYTICS: Use materialized views for aggregations (daily tool usage stats, etc.). DISTKEY: None (EVEN distribution - thread_id not suitable due to low cardinality). SORTKEY: event_timestamp first (time-series queries)';

-- 3. web_searches: Web search operations
-- Specialized fact table for search events
CREATE TABLE web_searches (
    search_id BIGINT IDENTITY(1,1),  -- PRIMARY KEY: Unique per search event
    tool_usage_id BIGINT NOT NULL ENCODE delta,  -- FK to tool_usage.tool_usage_id
    message_id VARCHAR(128) NOT NULL UNIQUE ENCODE zstd,  -- FK to chat_messages.message_id - 1:1 relationship (UNIQUE: one message = one search)
    thread_id VARCHAR(128) NOT NULL ENCODE zstd,  -- From JSON thread_id field - NOT unique, many messages per thread
    event_timestamp TIMESTAMP NOT NULL ENCODE delta32k,  -- From @timestamp
    search_type VARCHAR(20) ENCODE bytedict,  -- From request_body.web_search_options.search_type - low cardinality: 'auto', 'manual', etc.
    search_keywords VARCHAR(500) ENCODE zstd,  -- From reasoning_steps[i].web_search.search_keywords[] (join array with comma/space)
    num_results INTEGER ENCODE delta,  -- Raw number from len(response_body.search_results) or request_body.num_search_results - NOT an aggregation, raw fact data
    domain_category VARCHAR(50) ENCODE bytedict,  -- Denormalized from chat_messages.domain_category - for analytics without JOINs
    insert_timestamp TIMESTAMP DEFAULT GETDATE() ENCODE delta32k,
    
    SORTKEY(event_timestamp, search_type, thread_id)
)
ENCODE AUTO;

COMMENT ON TABLE web_searches IS 'Web search operations. Specialized fact table for search events. RELATIONSHIP: 1:1 with chat_messages.message_id (one message = one search). CLASSIFIER: Only created when Glue classifier selects web_search as the PRIMARY tool from reasoning_steps[]. Many searches can belong to one thread_id (many-to-one). FIELD EXTRACTION: search_type from request_body.web_search_options.search_type, search_keywords from reasoning_steps[i].web_search.search_keywords[] (join array), num_results from response_body.search_results (raw data). DOMAIN CLASSIFICATION: domain_category denormalized from chat_messages (for analytics without JOINs). ANALYTICS: Use materialized views for aggregations (daily search stats, search counts by domain, etc.). DISTKEY: None (EVEN distribution - thread_id not suitable due to low cardinality). SORTKEY: event_timestamp first (time-series queries)';

-- 4. browser_automations: Browser tool execution actions (non-web actions)
-- Specialized fact table for browser automation events
CREATE TABLE browser_automations (
    browser_action_id BIGINT IDENTITY(1,1),  -- PRIMARY KEY: Unique per browser action event
    tool_usage_id BIGINT NOT NULL ENCODE delta,  -- FK to tool_usage.tool_usage_id
    message_id VARCHAR(128) NOT NULL UNIQUE ENCODE zstd,  -- FK to chat_messages.message_id - 1:1 relationship (UNIQUE: one message = one browser action)
    thread_id VARCHAR(128) NOT NULL ENCODE zstd,  -- From JSON thread_id field - NOT unique, many messages per thread
    event_timestamp TIMESTAMP NOT NULL ENCODE delta32k,  -- From @timestamp
    step_type VARCHAR(50) ENCODE bytedict,  -- From reasoning_steps[i].browser_tool_execution.tool.step_type - low cardinality: 'SEARCH_BROWSER', etc. (NOT 'ENTROPY_REQUEST')
    domain_category VARCHAR(50) ENCODE bytedict,  -- Denormalized from chat_messages.domain_category - for analytics without JOINs
    user_id VARCHAR(128) ENCODE zstd,  -- User identifier for analytics
    insert_timestamp TIMESTAMP DEFAULT GETDATE() ENCODE delta32k,
    
    SORTKEY(event_timestamp, step_type, thread_id)
)
ENCODE AUTO;

COMMENT ON TABLE browser_automations IS 'Browser automation actions (non-web actions). Specialized fact table for browser tool execution events. RELATIONSHIP: 1:1 with chat_messages.message_id (one message = one browser action). CLASSIFIER: Only created when Glue classifier selects browser_tool_execution (with step_type != ENTROPY_REQUEST) as the PRIMARY tool from reasoning_steps[]. Many browser actions can belong to one thread_id (many-to-one). ROUTING: tool_type=browser_tool_execution AND step_type != ENTROPY_REQUEST (from response_body). Note: browser_tool_execution with step_type=ENTROPY_REQUEST routes to web_automations. FIELD EXTRACTION: step_type from reasoning_steps[i].browser_tool_execution.tool.step_type. DOMAIN CLASSIFICATION: domain_category denormalized from chat_messages (for analytics without JOINs). ANALYTICS: Use materialized views for aggregations (daily browser automation stats, etc.). DISTKEY: None (EVEN distribution - thread_id not suitable due to low cardinality). SORTKEY: event_timestamp first (time-series queries)';

-- 5. web_automations: Web automation actions (actual web interactions)
-- Specialized fact table for web action events - critical for Goal 2 analytics
CREATE TABLE web_automations (
    web_action_id BIGINT IDENTITY(1,1),  -- PRIMARY KEY: Unique per web action event
    tool_usage_id BIGINT NOT NULL ENCODE delta,  -- FK to tool_usage.tool_usage_id
    message_id VARCHAR(128) NOT NULL UNIQUE ENCODE zstd,  -- FK to chat_messages.message_id - 1:1 relationship (UNIQUE: one message = one web action)
    thread_id VARCHAR(128) NOT NULL ENCODE zstd,  -- From JSON thread_id field - NOT unique, many messages per thread
    event_timestamp TIMESTAMP NOT NULL ENCODE delta32k,  -- From @timestamp
    domain_category VARCHAR(50) NOT NULL ENCODE bytedict,  -- Denormalized from chat_messages.domain_category - CRITICAL for Goal 2 analytics and sort key optimization
    task_status VARCHAR(30) ENCODE bytedict,  -- From agent_progress.thought (if contains "Succeeded"/"Failed"/"In Progress") or infer from action='finished' - low cardinality
    task_completed BOOLEAN ENCODE runlength,  -- TRUE if "Succeeded" in agent_progress.thought OR action='finished', FALSE otherwise
    insert_timestamp TIMESTAMP DEFAULT GETDATE() ENCODE delta32k,
    
    SORTKEY(event_timestamp, domain_category)
)
ENCODE AUTO;

COMMENT ON TABLE web_automations IS 'Web automation actions (actual web interactions). Specialized fact table for web action events - critical for Goal 2 analytics. RELATIONSHIP: 1:1 with chat_messages.message_id (one message = one web action). CLASSIFIER: Only created when Glue classifier selects browser_tool_execution (with step_type=ENTROPY_REQUEST) OR agent_progress (with step_type=ENTROPY_REQUEST) as the PRIMARY tool from reasoning_steps[]. Many web actions can belong to one thread_id (many-to-one). ROUTING: (tool_type=browser_tool_execution OR tool_type=agent_progress) AND step_type=ENTROPY_REQUEST (from response_body). FIELD EXTRACTION: domain_name from URL (agent_progress.url or browser_tool_execution.tool.content.tasks[0].start_url), task_status/task_completed from agent_progress.thought. DOMAIN CLASSIFICATION: domain_category denormalized from chat_messages (Shopping, Booking, etc.) - CRITICAL for Goal 2 analytics and sort key optimization. ANALYTICS: Use materialized views for aggregations (daily web action stats by domain, etc.). DISTKEY: None (EVEN distribution - thread_id not suitable due to low cardinality). SORTKEY: event_timestamp, domain_category (for Goal 2 analytics)';

-- 6. usage_metrics: Token usage, cost, latency metrics
-- Fact table for usage and cost metrics
CREATE TABLE usage_metrics (
    metric_id BIGINT IDENTITY(1,1),  -- PRIMARY KEY: Unique per usage metric event
    message_id VARCHAR(128) ENCODE zstd,  -- FK to chat_messages.message_id - optional, for traceability
    thread_id VARCHAR(128) NOT NULL ENCODE zstd,  -- From JSON thread_id field - NOT unique, many messages per thread
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
    model VARCHAR(64) ENCODE bytedict,  -- From response_body.model - limited model names, low cardinality
    insert_timestamp TIMESTAMP DEFAULT GETDATE() ENCODE delta32k,
    
    SORTKEY(event_timestamp, model, thread_id)
)
ENCODE AUTO;

COMMENT ON TABLE usage_metrics IS 'Token usage, cost, and latency metrics. Fact table for usage and cost metrics. RELATIONSHIP: Many metrics can belong to one thread_id (many-to-one). FIELD EXTRACTION: All fields from response_body.usage.* (completion_tokens, prompt_tokens, total_tokens, cost.*, search_context_size), latency_ms pre-calculated, model from response_body.model. LATENCY: request_timestamp and response_timestamp enable detailed latency analysis, time-of-day patterns, and performance correlation with costs. ANALYTICS: Use materialized views for aggregations (daily cost stats, token usage by model, cost by domain, etc.). DISTKEY: None (EVEN distribution - thread_id not suitable due to low cardinality). SORTKEY: event_timestamp first (time-series queries)';

-- 7. domain_classifications: Domain categorization reference table
-- Reference/lookup table for domain categories (training/examples only)
CREATE TABLE domain_classifications (
    domain_name VARCHAR(255) NOT NULL ENCODE zstd,  -- Domain name (for reference only - classification is query-based)
    domain_category VARCHAR(50) NOT NULL ENCODE bytedict,  -- Category: 'Shopping', 'Booking', 'Entertainment', 'Work', 'Education', 'Finance'
    subcategory VARCHAR(50) ENCODE bytedict,  -- Low cardinality: 'E-commerce', 'Travel', 'Media', etc.
    intent_type VARCHAR(30) ENCODE bytedict,  -- Intent type: 'Transactional', 'Informational', 'Social', 'Entertainment', 'Productivity'
    query_patterns VARCHAR(500) ENCODE zstd,  -- Example query patterns that map to this category (for reference/training only)
    is_active BOOLEAN DEFAULT TRUE ENCODE runlength,
    created_timestamp TIMESTAMP DEFAULT GETDATE() ENCODE delta32k,
    updated_timestamp TIMESTAMP DEFAULT GETDATE() ENCODE delta32k,
    
    DISTKEY(domain_name),
    SORTKEY(domain_category, intent_type, domain_name)
)
ENCODE AUTO;

COMMENT ON TABLE domain_classifications IS 'Reference table for domain categories (training/examples only). IMPORTANT: This is a REFERENCE table only, NOT used for lookup during ETL. Domain classification is done by intent classifier analyzing user_query from request_body (NOT via table lookup). This table stores example patterns and metadata for reference. Classification results are stored denormalized in chat_messages.domain_category and web_automations.domain_category. ANALYTICS: Use materialized views for aggregations if needed. DISTKEY: domain_name (reference table, small size). SORTKEY: domain_category first (for filtering)';

-- 8. message_response_content: Large response content storage (separate table for rarely accessed content)
-- OPTIMIZATION: Separated from chat_messages to improve query performance when response_content is not needed
-- REDSHIFT BEST PRACTICE: Large text fields stored separately to avoid reading them in columnar queries
CREATE TABLE message_response_content (
    message_id VARCHAR(128) NOT NULL PRIMARY KEY,  -- FK to chat_messages.message_id - 1:1 relationship
    response_content VARCHAR(65535) ENCODE zstd,  -- From response_body.choices[0].message.content - large TEXT field (up to 65KB)
    insert_timestamp TIMESTAMP DEFAULT GETDATE() ENCODE delta32k,
    
    SORTKEY(message_id)
)
ENCODE AUTO;

COMMENT ON TABLE message_response_content IS 'Large response content storage. OPTIMIZATION: Separated from chat_messages to improve query performance. REDSHIFT BEST PRACTICE: Large text fields (response_content) stored in separate table to avoid reading them in columnar queries when not needed. RELATIONSHIP: 1:1 with chat_messages.message_id. USE CASE: Only query this table when you need the actual response text content. For analytics queries, use chat_messages table which contains metadata (finish_reason, model, response_type) without the large content field. This reduces I/O and improves query performance for most analytics use cases.';

-- Sample domain classifications
INSERT INTO domain_classifications (domain_name, domain_category, subcategory, intent_type) VALUES
('www.kurly.com', 'Shopping', 'E-commerce', 'Transactional'),
('www.amazon.com', 'Shopping', 'E-commerce', 'Transactional'),
('www.trip.com', 'Booking', 'Travel', 'Transactional'),
('devtalk.kakao.com', 'Work', 'Developer Tools', 'Informational'),
('developers.kakao.com', 'Work', 'Developer Tools', 'Informational'),
('www.google.com', 'Work', 'Search', 'Informational'),
('www.youtube.com', 'Entertainment', 'Media', 'Entertainment');
