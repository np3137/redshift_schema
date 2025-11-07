-- ============================================
-- Base Tables for Chat Analytics - Redshift Schema
-- ============================================
-- KEY RELATIONSHIPS:
-- - message_id: UNIQUE per message (PRIMARY KEY) - unique identifier of a message
-- - thread_id: NOT unique per message - many messages can belong to one thread (many-to-one relationship). NOT a unique identifier of a message
-- - room_id: NOT unique per message - many messages can belong to one room (many-to-one relationship). NOT a unique identifier of a message
-- - CLASSIFIER: Glue classifier selects ONE tool_type from reasoning_steps[] per message (others in JSON discarded)
-- - MULTIPLE SUBDOMAINS PER MESSAGE: ONE tool_type (e.g., web_automation) can have MULTIPLE subdomain intents 
--   in a single message - stored in tool_subdomains junction table (one row per subdomain). Intent classifier 
--   identifies multiple intents from user_query (e.g., "order food and schedule delivery" → domain="Transactional", 
--   subdomains="food_order" and "delivery" as separate rows in tool_subdomains)
-- - CONSOLIDATED SCHEMA: All tool classification fields (tool_type, step_type, classification_target, domain) 
--   are stored directly in chat_messages table, eliminating the need for a separate tool_actions table
-- REDSHIFT BEST PRACTICES:
-- - Base tables store raw fact data only (no aggregations)
-- - Materialized views handle all aggregations and analytics
-- - DISTKEY: None (EVEN distribution) - thread_id has low cardinality (many messages per thread), not suitable for distribution
-- - SORTKEY: event_timestamp first (time-series queries)
-- - Appropriate encoding for each column type

-- 1. chat_messages: Main message/request level data
-- Core fact table for individual chat messages
-- RELATIONSHIP: Many messages can belong to one thread_id or room_id (many-to-one)
-- IMPORTANT: thread_id and room_id are NOT unique identifiers of a message - they are relationship fields
CREATE TABLE chat_messages (
    message_id VARCHAR(128) NOT NULL PRIMARY KEY,  -- UNIQUE: From _id.$oid (if available) OR generated from response_id OR thread_id+@timestamp - unique per message
    room_id VARCHAR(128) NOT NULL ENCODE zstd,  -- From JSON room_id field - NOT unique per message, many messages can belong to one room (many-to-one relationship)
    thread_id VARCHAR(128) NOT NULL ENCODE zstd,  -- From JSON thread_id field - NOT unique per message, many messages can belong to one thread (many-to-one relationship). NOT a unique identifier of a message
    event_timestamp TIMESTAMP NOT NULL ENCODE delta32k,  -- From @timestamp (top-level)
    request_timestamp TIMESTAMP ENCODE delta32k,  -- From @timestamp - for latency calculation
    response_timestamp TIMESTAMP ENCODE delta32k,  -- From response_body.created (Unix timestamp) - for latency calculation
    tool_type VARCHAR(30) NOT NULL ENCODE bytedict,  -- From Glue classifier selection - ONE tool chosen from reasoning_steps[] - low cardinality: 'web_search', 'browser_tool_execution', 'agent_progress'
    step_type VARCHAR(50) ENCODE bytedict,  -- From selected reasoning step - low cardinality: 'ENTROPY_REQUEST', 'SEARCH_BROWSER', etc.
    classification_target VARCHAR(30) ENCODE bytedict,  -- Glue classifier routing output - 'browser_automation', 'web_automation', 'web_search', 'none'
    domain VARCHAR(50) ENCODE bytedict,  -- From intent classifier analyzing user_query from chat_messages.user_query (e.g., 'Transactional', 'Informational') - SOURCE OF TRUTH. NOT NULL for web_automation (CRITICAL for Goal 2)
    user_query VARCHAR(2000) ENCODE zstd,  -- From request_body.messages[0].content - input for intent classifier
    task_completed BOOLEAN ENCODE runlength,  -- Boolean benefits from runlength encoding
    task_completion_status VARCHAR(20) ENCODE bytedict,  -- Low cardinality: 'completed', 'failed', 'partial', 'in_progress', 'cancelled'
    -- Response metadata fields (frequently used in analytics)
    finish_reason VARCHAR(20) ENCODE bytedict,  -- From response_body.choices[0].finish_reason - low cardinality: 'stop', 'length', 'content_filter', etc.
    model VARCHAR(64) ENCODE bytedict,  -- From response_body.model - limited model names, low cardinality
    response_type VARCHAR(30) ENCODE bytedict,  -- From response_body.type - low cardinality: 'end_of_stream', etc.
    
    SORTKEY(event_timestamp, thread_id)
)
ENCODE AUTO;

COMMENT ON TABLE chat_messages IS 'Main message/request level data. Core fact table storing raw message and response metadata. UNIQUENESS: message_id is PRIMARY KEY (unique per message). RELATIONSHIP: Many messages can belong to one thread_id or room_id (many-to-one). thread_id and room_id are NOT unique identifiers of a message - they are relationship fields. IMPORTANT: If _id.$oid not in JSON, generate message_id from response_id OR thread_id+@timestamp. TOOL SELECTION: Only ONE tool_type per message is selected from JSON (others discarded if multiple exist). TOOL CLASSIFICATION: tool_type, step_type, classification_target, and domain are stored directly in this table (from Glue classifier and intent classifier). tool_type from Glue classifier selection (one message = one tool: web_search, browser_tool_execution, agent_progress). classification_target determined by tool_type and step_type combination. domain (SOURCE OF TRUTH) from intent classifier analyzing user_query. RESPONSE FIELDS: finish_reason, model, response_type stored here (frequently used in analytics). Large response_content moved to message_response_content table (separate table for rarely accessed large content). LATENCY: request_timestamp and response_timestamp enable latency calculation. TASK STATUS: task_completion_status and task_completed track message-level task status. ANALYTICS: Use materialized views for aggregations (daily stats, domain analytics, etc.). DISTKEY: None (EVEN distribution - thread_id/room_id not suitable due to low cardinality). SORTKEY: event_timestamp first (time-series queries), thread_id for filtering';


-- 2. tool_subdomains: Junction table for multiple subdomains per message
-- Normalized table to support multiple subdomains per message (one row per subdomain)
CREATE TABLE tool_subdomains (
    subdomain_id BIGINT IDENTITY(1,1),  -- PRIMARY KEY: Unique per subdomain record
    message_id VARCHAR(128) NOT NULL ENCODE zstd,  -- FK to chat_messages.message_id
    subdomain VARCHAR(50) NOT NULL ENCODE bytedict,  -- Individual subdomain intent (e.g., 'food_order', 'delivery', 'shopping', 'booking') - ONE subdomain per row - SOURCE OF TRUTH
    event_timestamp TIMESTAMP NOT NULL ENCODE delta32k,  -- Denormalized from chat_messages.event_timestamp for time-series queries
    
    SORTKEY(message_id, subdomain)
)
ENCODE AUTO;

COMMENT ON TABLE tool_subdomains IS 'Junction table for multiple subdomains per message. NORMALIZED STRUCTURE: One row per subdomain intent (supports multiple subdomains per message). RELATIONSHIP: Many-to-one with chat_messages (one message can have multiple subdomain records). MULTIPLE SUBDOMAINS: ONE tool_type can have MULTIPLE intents in a single message - each intent stored as a separate row. For example, if intent classifier identifies "food_order" and "delivery" from user_query, this creates two rows: one with subdomain="food_order" and one with subdomain="delivery". SOURCE OF TRUTH: Individual subdomain values stored here (not comma-separated). DOMAIN: Domain is stored in chat_messages table (join required for domain+subdomain queries). ANALYTICS: Join with chat_messages for domain/subdomain analytics. Use for subdomain-level aggregations and filtering. Example: Find all messages with subdomain="food_order" regardless of other subdomains. DISTKEY: None (EVEN distribution). SORTKEY: message_id first (for joins), subdomain for filtering';

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
    
    SORTKEY(event_timestamp, thread_id)
)
ENCODE AUTO;

COMMENT ON TABLE usage_metrics IS 'Token usage, cost, and latency metrics. Fact table for usage and cost metrics. RELATIONSHIP: Many metrics can belong to one thread_id (many-to-one). thread_id is NOT a unique identifier of a message - it is a relationship field. FIELD EXTRACTION: All fields from response_body.usage.* (completion_tokens, prompt_tokens, total_tokens, cost.*, search_context_size), latency_ms pre-calculated. LATENCY: request_timestamp and response_timestamp enable detailed latency analysis, time-of-day patterns, and performance correlation with costs. ANALYTICS: Use materialized views for aggregations (daily cost stats, token usage, cost by domain, etc.). DISTKEY: None (EVEN distribution - thread_id not suitable due to low cardinality). SORTKEY: event_timestamp first (time-series queries), thread_id for filtering';


-- 5. message_response_content: Large response content storage (separate table for rarely accessed content)
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

-- ============================================
-- SCHEMA SUMMARY
-- ============================================
-- Total Tables: 4
-- 1. chat_messages - Core message fact table (includes tool_type, step_type, classification_target, domain)
-- 2. tool_subdomains - Junction table for multiple subdomains per message (normalized - one row per subdomain)
-- 3. usage_metrics - Token usage, cost, and latency metrics
-- 4. message_response_content - Large response content (separated for performance)
--
-- KEY DESIGN DECISIONS:
-- - All tool classification fields (tool_type, step_type, classification_target, domain) stored directly in chat_messages
-- - Domain stored in chat_messages (SOURCE OF TRUTH) - calculated by intent classifier from chat_messages.user_query
-- - Multiple subdomains per message supported via normalized junction table (tool_subdomains) - one row per subdomain
-- - One tool_type per message (others discarded if multiple exist)
-- - Large content separated for query performance optimization
-- - Normalized subdomain structure enables better querying and analytics on individual subdomains
--
-- QUERY OPTIMIZATION TIPS:
-- 1. Always filter by SORTKEY columns first (event_timestamp, thread_id for chat_messages)
-- 2. Use WHERE tool_type = 'web_automation' for Goal 2 analytics
-- 3. Filter by domain early when querying chat_messages
-- 4. Use materialized views for common aggregations
-- 5. Avoid SELECT * on message_response_content unless needed
-- 6. Join on message_id for relationships (already optimized)
--
-- COMMON QUERY PATTERNS:
-- - Goal 2 Analytics: SELECT * FROM chat_messages WHERE tool_type='web_automation' AND domain='Transactional'
-- - Daily Stats: GROUP BY DATE(event_timestamp), tool_type FROM chat_messages
-- - Domain Analytics: SELECT cm.domain, ts.subdomain, COUNT(*) FROM chat_messages cm JOIN tool_subdomains ts ON cm.message_id = ts.message_id WHERE cm.tool_type='web_automation' GROUP BY cm.domain, ts.subdomain
-- - Subdomain Count: SELECT subdomain, COUNT(*) FROM tool_subdomains GROUP BY subdomain
-- - Messages with specific subdomain: SELECT cm.* FROM chat_messages cm JOIN tool_subdomains ts ON cm.message_id = ts.message_id WHERE ts.subdomain='food_order'
-- - Cost Analysis: JOIN usage_metrics with chat_messages on message_id

