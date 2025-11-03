-- ============================================
-- Base Tables for Chat Analytics
-- ============================================

-- 1. chat_sessions: Main session/thread level data
-- Contains only session-level metadata (from top-level and request_body)
-- REFACTORED: Optimized VARCHAR sizes, added event_date for better sort key performance
-- INTENT CLASSIFIER: user_query from request_body is analyzed for domain classification
-- LATENCY: Added request_timestamp for session-level latency analysis
CREATE TABLE chat_sessions (
    session_id VARCHAR(128) NOT NULL ENCODE zstd,  -- Optimized size, high compression
    thread_id VARCHAR(128) NOT NULL ENCODE zstd,
    event_timestamp TIMESTAMP NOT NULL ENCODE delta32k,
    event_date DATE ENCODE zstd,  -- Populated in ETL as DATE(event_timestamp) for better sort key performance
    request_timestamp TIMESTAMP ENCODE delta32k,  -- LATENCY: When user request was received (from request_body timestamp or @timestamp)
    created_timestamp TIMESTAMP ENCODE delta32k,
    response_id VARCHAR(128) ENCODE zstd,  -- FK to responses table (from response_body.id)
    user_query VARCHAR(2000) ENCODE zstd,  -- INTENT CLASSIFIER INPUT: User query from request_body (analyzed for domain classification)
    task_completed BOOLEAN ENCODE runlength,  -- Boolean benefits from runlength encoding
    task_completion_status VARCHAR(20) ENCODE bytedict,  -- Low cardinality: 'completed', 'failed', 'partial', 'in_progress', 'cancelled'
    task_completion_reason VARCHAR(500) ENCODE zstd,
    insert_timestamp TIMESTAMP DEFAULT GETDATE() ENCODE delta32k,
    
    DISTKEY(session_id),
    SORTKEY(event_date, event_timestamp, thread_id)  -- REFACTORED: event_date first for date range queries, then timestamp
)
ENCODE AUTO;

COMMENT ON TABLE chat_sessions IS 'Main session/thread level data. INTENT CLASSIFIER: user_query from request_body analyzed for domain classification. LATENCY: request_timestamp added for session-level latency tracking. REFACTORED: Optimized data types, added event_date, improved sort key. DISTKEY: session_id';

-- 1b. responses: Response content and metadata from AI
-- Contains all response_body fields needed for analytics (normalized approach)
-- REFACTORED: Optimized VARCHAR sizes, better encodings for low-cardinality fields
CREATE TABLE responses (
    response_id VARCHAR(128) NOT NULL ENCODE zstd,
    session_id VARCHAR(128) NOT NULL ENCODE zstd,
    thread_id VARCHAR(128) NOT NULL ENCODE zstd,
    event_timestamp TIMESTAMP NOT NULL ENCODE delta32k,
    event_date DATE ENCODE zstd,  -- Populated in ETL as DATE(event_timestamp) for better sort key performance
    created_timestamp TIMESTAMP ENCODE delta32k, -- From response_body.created
    response_content VARCHAR(65535) ENCODE zstd,  -- Changed from TEXT to VARCHAR(65535) for better compression control
    finish_reason VARCHAR(20) ENCODE bytedict, -- Low cardinality: 'stop', 'length', 'content_filter', etc.
    model VARCHAR(64) ENCODE bytedict,  -- Limited model names, low cardinality
    status VARCHAR(20) ENCODE bytedict, -- Low cardinality: 'COMPLETED', 'FAILED', etc.
    type VARCHAR(30) ENCODE bytedict, -- Low cardinality: 'end_of_stream', etc.
    insert_timestamp TIMESTAMP DEFAULT GETDATE() ENCODE delta32k,
    
    DISTKEY(session_id),
    SORTKEY(event_date, event_timestamp, thread_id)  -- REFACTORED: event_date first for date range queries
)
ENCODE AUTO;

COMMENT ON TABLE responses IS 'AI response content and metadata. REFACTORED: Optimized data types, added event_date, improved sort key. DISTKEY: session_id';

-- 2. tool_usage: Individual tool call records (all types)
-- REFACTORED: Optimized VARCHAR sizes, better encodings for categorical fields
-- INTENT CLASSIFIER WORKFLOW: This is the source table for intent classification.
-- ETL uses tool_type and step_type to route records to either browser_automations or web_automations.
CREATE TABLE tool_usage (
    tool_usage_id BIGINT IDENTITY(1,1),
    session_id VARCHAR(128) NOT NULL ENCODE zstd,
    thread_id VARCHAR(128) NOT NULL ENCODE zstd,
    event_timestamp TIMESTAMP NOT NULL ENCODE delta32k,
    event_date DATE NOT NULL ENCODE zstd,  -- Populated in ETL as DATE(event_timestamp) for better sort key performance
    tool_type VARCHAR(30) NOT NULL ENCODE bytedict, -- Low cardinality: 'web_search', 'browser_tool_execution', 'agent_progress'
    step_type VARCHAR(50) ENCODE bytedict, -- Low cardinality: 'ENTROPY_REQUEST', etc.
    classification_target VARCHAR(30) ENCODE bytedict, -- INTENT CLASSIFIER OUTPUT: 'browser_automation', 'web_automation', 'web_search', 'none'
    insert_timestamp TIMESTAMP DEFAULT GETDATE() ENCODE delta32k,
    
    DISTKEY(session_id),
    SORTKEY(event_date, tool_type, thread_id)  -- REFACTORED: tool_type before thread_id (more selective)
)
ENCODE AUTO;

COMMENT ON TABLE tool_usage IS 'All tool usage events from reasoning_steps array. INTENT CLASSIFIER: tool_type and step_type are used by intent classifier to determine classification_target. REFACTORED: Optimized data types and sort key. DISTKEY: session_id. ETL MUST populate event_date = DATE(event_timestamp)';

-- 3. web_searches: Web search operations
-- REFACTORED: Optimized VARCHAR sizes, better encodings
-- AGGREGATIONS: Counts and aggregations should be done in materialized views, not stored here
CREATE TABLE web_searches (
    search_id BIGINT IDENTITY(1,1),
    tool_usage_id BIGINT NOT NULL ENCODE delta,
    session_id VARCHAR(128) NOT NULL ENCODE zstd,
    thread_id VARCHAR(128) NOT NULL ENCODE zstd,
    event_timestamp TIMESTAMP NOT NULL ENCODE delta32k,
    event_date DATE NOT NULL ENCODE zstd,  -- Populated in ETL as DATE(event_timestamp) for better sort key performance
    search_type VARCHAR(20) ENCODE bytedict, -- Low cardinality: 'auto', 'manual', etc.
    search_keywords VARCHAR(500) ENCODE zstd,  -- Changed from TEXT to VARCHAR with encoding
    num_results INTEGER ENCODE delta,  -- Raw number of results from search response (not an aggregation)
    insert_timestamp TIMESTAMP DEFAULT GETDATE() ENCODE delta32k,
    
    DISTKEY(session_id),
    SORTKEY(event_date, search_type, thread_id)  -- REFACTORED: search_type before thread_id for better selectivity
)
ENCODE AUTO;

COMMENT ON TABLE web_searches IS 'Web search operations. AGGREGATIONS: Counts and aggregations done in materialized views. REFACTORED: Optimized data types and sort key. DISTKEY: session_id. ETL MUST populate: event_date';

-- 4. browser_automations: Browser tool execution actions
-- INTENT CLASSIFIER WORKFLOW: Records are routed here by intent classifier based on:
-- - tool_type = 'browser_tool_execution' → browser_automations
-- - Records come FROM tool_usage table AFTER classification
-- REFACTORED: Added event_date for consistent date queries, optimized data types
CREATE TABLE browser_automations (
    browser_action_id BIGINT IDENTITY(1,1),
    tool_usage_id BIGINT NOT NULL ENCODE delta,  -- FK to tool_usage (after intent classification)
    session_id VARCHAR(128) NOT NULL ENCODE zstd,
    thread_id VARCHAR(128) NOT NULL ENCODE zstd,
    event_timestamp TIMESTAMP NOT NULL ENCODE delta32k,
    event_date DATE NOT NULL ENCODE zstd,  -- REFACTORED: Added for consistent date-based queries and sort key optimization
    action_type VARCHAR(50) ENCODE bytedict, -- Extracted from browser_tool_execution, low cardinality
    step_type VARCHAR(50) ENCODE bytedict, -- Low cardinality: 'ENTROPY_REQUEST'
    user_id VARCHAR(128) ENCODE zstd, -- User identifier for analytics
    classification_confidence DECIMAL(3,2) ENCODE delta32k, -- INTENT CLASSIFIER: Confidence score (0.00-1.00) if available
    insert_timestamp TIMESTAMP DEFAULT GETDATE() ENCODE delta32k,
    
    DISTKEY(session_id),
    SORTKEY(event_date, action_type, thread_id)  -- REFACTORED: event_date first, action_type before thread_id for better selectivity
)
ENCODE AUTO;

COMMENT ON TABLE browser_automations IS 'Browser automation actions. INTENT CLASSIFIER: Records routed here when tool_type=browser_tool_execution. REFACTORED: Added event_date, optimized data types and sort key. DISTKEY: session_id';

-- 5. web_automations: Web automation actions (ENTROPY_REQUEST steps)
-- INTENT CLASSIFIER WORKFLOW: Records are routed here by intent classifier based on:
-- - tool_type = 'agent_progress' AND step_type = 'ENTROPY_REQUEST' → web_automations
-- - Records come FROM tool_usage table AFTER classification
-- DOMAIN CLASSIFICATION: domain_category populated by intent classifier based on user_query analysis
-- REFACTORED: Optimized VARCHAR sizes, better encodings for categorical fields
CREATE TABLE web_automations (
    web_action_id BIGINT IDENTITY(1,1),
    tool_usage_id BIGINT NOT NULL ENCODE delta,  -- FK to tool_usage (after intent classification)
    session_id VARCHAR(128) NOT NULL ENCODE zstd,
    thread_id VARCHAR(128) NOT NULL ENCODE zstd,
    event_timestamp TIMESTAMP NOT NULL ENCODE delta32k,
    event_date DATE NOT NULL ENCODE zstd,  -- Populated in ETL as DATE(event_timestamp) for better sort key performance
    action_type VARCHAR(50) ENCODE bytedict, -- Low cardinality: 'click', 'search', 'add_to_cart', etc. - REQUIRED for Goal 2 action analysis
    domain_category VARCHAR(50) NOT NULL ENCODE bytedict, -- INTENT CLASSIFIER OUTPUT: From analyzing user_query in request_body (Shopping, Booking, Entertainment, Work, etc.) - NOT from domain_classifications lookup
    domain_name VARCHAR(255) NOT NULL ENCODE zstd, -- Extracted from URL
    task_status VARCHAR(30) ENCODE bytedict, -- Low cardinality: 'Succeeded', 'In Progress', 'Failed', etc.
    task_completed BOOLEAN ENCODE runlength, -- Whether this specific task/action completed successfully
    classification_confidence DECIMAL(3,2) ENCODE delta32k, -- INTENT CLASSIFIER: Confidence score (0.00-1.00) for domain classification
    insert_timestamp TIMESTAMP DEFAULT GETDATE() ENCODE delta32k,
    
    DISTKEY(session_id),
    SORTKEY(event_date, domain_category, action_type)  -- REFACTORED: domain_category before action_type (more selective)
)
ENCODE AUTO;

COMMENT ON TABLE web_automations IS 'Web automation actions. INTENT CLASSIFIER: Records routed here when tool_type=agent_progress AND step_type=ENTROPY_REQUEST. DOMAIN CLASSIFICATION: domain_category from intent classifier based on user_query analysis. OPTIMIZED: Removed action_url (use domain_name instead - extracted during ETL). REFACTORED: Optimized data types and sort key. DISTKEY: session_id. ETL MUST populate domain_category, domain_name (from URL extraction), and event_date';

-- 6. usage_metrics: Token usage, cost, latency metrics
-- REFACTORED: Optimized VARCHAR sizes, better encodings for categorical fields
-- LATENCY: Added request_timestamp and response_timestamp for detailed latency analysis
CREATE TABLE usage_metrics (
    metric_id BIGINT IDENTITY(1,1),
    session_id VARCHAR(128) NOT NULL ENCODE zstd,
    thread_id VARCHAR(128) NOT NULL ENCODE zstd,
    event_timestamp TIMESTAMP NOT NULL ENCODE delta32k,
    event_date DATE NOT NULL ENCODE zstd,  -- Populated in ETL as DATE(event_timestamp) for better sort key performance
    request_timestamp TIMESTAMP ENCODE delta32k,  -- LATENCY: When request was sent to AI service (from request_body or system log)
    response_timestamp TIMESTAMP ENCODE delta32k,  -- LATENCY: When response was received (from response_body.created or system log)
    completion_tokens INTEGER ENCODE delta,
    prompt_tokens INTEGER ENCODE delta,
    total_tokens INTEGER ENCODE delta,
    input_tokens_cost DOUBLE PRECISION ENCODE delta32k,
    output_tokens_cost DOUBLE PRECISION ENCODE delta32k,
    request_cost DOUBLE PRECISION ENCODE delta32k,
    total_cost DOUBLE PRECISION ENCODE delta32k,
    search_context_size VARCHAR(10) ENCODE bytedict, -- Low cardinality: 'low', 'medium', 'high'
    latency_ms INTEGER ENCODE delta,  -- Pre-calculated latency (can be validated against timestamps)
    model VARCHAR(64) ENCODE bytedict,  -- Limited model names, low cardinality
    insert_timestamp TIMESTAMP DEFAULT GETDATE() ENCODE delta32k,
    
    DISTKEY(session_id),
    SORTKEY(event_date, model, thread_id)  -- REFACTORED: model before thread_id for better selectivity
)
ENCODE AUTO;

COMMENT ON TABLE usage_metrics IS 'Token usage, cost, and latency metrics. LATENCY: request_timestamp and response_timestamp enable detailed latency analysis, time-of-day patterns, and performance correlation with costs. REFACTORED: Optimized data types and sort key. DISTKEY: session_id. ETL MUST populate event_date, request_timestamp, and response_timestamp';

-- 7. domain_classifications: Domain categorization reference table
-- IMPORTANT: This is a REFERENCE table only, NOT used for lookup during ETL
-- Domain classification is done by intent classifier analyzing user_query from request_body
-- This table stores examples, patterns, and metadata for reference/training purposes
-- REFACTORED: Optimized VARCHAR sizes, better encodings for categorical fields
CREATE TABLE domain_classifications (
    domain_name VARCHAR(255) NOT NULL ENCODE zstd,  -- Domain name (optional, for reference only - classification is query-based)
    domain_category VARCHAR(50) NOT NULL ENCODE bytedict, -- Category: 'Shopping', 'Booking', 'Entertainment', 'Work', 'Education', 'Finance'
    subcategory VARCHAR(50) ENCODE bytedict, -- Low cardinality: 'E-commerce', 'Travel', 'Media', etc.
    intent_type VARCHAR(30) ENCODE bytedict, -- Intent type: 'Transactional', 'Informational', 'Social', 'Entertainment', 'Productivity'
    query_patterns VARCHAR(500) ENCODE zstd,  -- EXAMPLE query patterns that map to this category (for reference/training only)
    is_active BOOLEAN DEFAULT TRUE ENCODE runlength,
    created_timestamp TIMESTAMP DEFAULT GETDATE() ENCODE delta32k,
    updated_timestamp TIMESTAMP DEFAULT GETDATE() ENCODE delta32k,
    
    DISTKEY(domain_name),
    SORTKEY(domain_category, intent_type, domain_name)  -- REFACTORED: intent_type added for better filtering
)
ENCODE AUTO;

COMMENT ON TABLE domain_classifications IS 'Reference table for domain categories (training/examples only). DOMAIN CLASSIFICATION: Actual classification is done by intent classifier analyzing user_query from request_body (NOT via table lookup). This table stores example patterns and metadata for reference. Classification results are stored denormalized in web_automations.domain_category. REFACTORED: Optimized data types and sort key. DISTKEY: domain_name';

-- Sample domain classifications
INSERT INTO domain_classifications (domain_name, domain_category, subcategory, intent_type) VALUES
('www.kurly.com', 'Shopping', 'E-commerce', 'Transactional'),
('www.amazon.com', 'Shopping', 'E-commerce', 'Transactional'),
('www.trip.com', 'Booking', 'Travel', 'Transactional'),
('devtalk.kakao.com', 'Work', 'Developer Tools', 'Informational'),
('developers.kakao.com', 'Work', 'Developer Tools', 'Informational'),
('www.google.com', 'Work', 'Search', 'Informational'),
('www.youtube.com', 'Entertainment', 'Media', 'Entertainment');

