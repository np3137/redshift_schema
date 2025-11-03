-- ============================================
-- Helper Views and Functions
-- ============================================

-- View: Extract domain names (from stored domain_name field)
-- UPDATED: Uses stored domain_name field instead of extracting from action_url (removed)
CREATE OR REPLACE VIEW v_extracted_domains AS
SELECT DISTINCT
    domain_name,
    domain_name AS base_domain,  -- Same as domain_name (no subdomain distinction needed)
    domain_category
FROM web_automations
WHERE domain_name IS NOT NULL;

COMMENT ON VIEW v_extracted_domains IS 'Helper view for unique domains. OPTIMIZED: Uses stored domain_name field instead of extracting from action_url (removed for storage efficiency)';

-- View: Complete tool usage with details
-- REFACTORED: Removed reference to deleted 'thought' field
-- LATENCY: Added latency analysis from timestamps
CREATE OR REPLACE VIEW v_tool_usage_details AS
SELECT 
    tu.tool_usage_id,
    tu.session_id,
    tu.thread_id,
    tu.event_timestamp,
    tu.event_date,
    tu.tool_type,
    tu.step_type,
    r.model,  -- From responses table (normalized)
    r.status AS response_status,  -- From responses table (normalized)
    um.total_tokens,
    um.total_cost,
    um.latency_ms AS reported_latency_ms,
    -- Calculated latency from timestamps (more accurate)
    CASE 
        WHEN um.request_timestamp IS NOT NULL AND um.response_timestamp IS NOT NULL 
        THEN EXTRACT(EPOCH FROM (um.response_timestamp - um.request_timestamp)) * 1000 
        ELSE um.latency_ms 
    END AS calculated_latency_ms,
    um.request_timestamp,
    um.response_timestamp
FROM tool_usage tu
LEFT JOIN chat_sessions cs ON tu.session_id = cs.session_id 
    AND tu.thread_id = cs.thread_id
LEFT JOIN responses r ON cs.response_id = r.response_id  -- Join responses for model/status
LEFT JOIN usage_metrics um ON tu.session_id = um.session_id 
    AND tu.thread_id = um.thread_id;

COMMENT ON VIEW v_tool_usage_details IS 'Complete tool usage information with session and metrics details. LATENCY: Includes calculated latency from request/response timestamps. REFACTORED: Added event_date, removed thought field';

-- View: Web automation actions with domain classification
-- REFACTORED: Removed reference to deleted 'thought' field, optimized to use pre-populated domain_category
CREATE OR REPLACE VIEW v_web_automations_classified AS
SELECT 
    wa.web_action_id,
    wa.session_id,
    wa.thread_id,
    wa.event_timestamp,
    wa.event_date,
    wa.action_type,
    wa.task_status,
    wa.domain_category,  -- Already populated in ETL (no COALESCE needed)
    COALESCE(dc.subcategory, 'Unknown') AS subcategory,
    COALESCE(dc.intent_type, 'Unknown') AS intent_type,
    wa.domain_name
FROM web_automations wa
LEFT JOIN domain_classifications dc ON wa.domain_name = dc.domain_name 
    AND dc.is_active = TRUE;

COMMENT ON VIEW v_web_automations_classified IS 'Web automation actions with domain classification. REFACTORED: Added event_date, removed thought field, uses pre-populated domain_category';

-- View: Search operations summary
-- AGGREGATIONS: No pre-calculated aggregations - use materialized views for counts
CREATE OR REPLACE VIEW v_search_operations AS
SELECT 
    ws.search_id,
    ws.session_id,
    ws.thread_id,
    ws.event_timestamp,
    ws.event_date,
    ws.search_type,
    ws.search_keywords,
    ws.num_results  -- Raw number of results from search response
FROM web_searches ws;

COMMENT ON VIEW v_search_operations IS 'Search operations summary. AGGREGATIONS: Counts and aggregations should be queried from materialized views (e.g., mv_web_search_statistics)';

-- View: Complete session with response content
-- REFACTORED: Removed references to deleted fields (room_id, object)
CREATE OR REPLACE VIEW v_sessions_with_responses AS
SELECT 
    cs.session_id,
    cs.thread_id,
    cs.event_timestamp,
    cs.event_date,
    cs.created_timestamp,
    cs.response_id,
    cs.task_completed,
    cs.task_completion_status,
    r.model,  -- From responses table (normalized)
    r.status AS response_status,  -- From responses table (normalized)
    r.type AS response_type,  -- From responses table (normalized)
    r.response_content,
    r.finish_reason,
    r.created_timestamp AS response_created_timestamp,
    um.total_tokens,
    um.total_cost
FROM chat_sessions cs
LEFT JOIN responses r ON cs.response_id = r.response_id  -- Join to get all response fields
LEFT JOIN usage_metrics um ON cs.session_id = um.session_id 
    AND cs.thread_id = um.thread_id;

COMMENT ON VIEW v_sessions_with_responses IS 'Complete session information with response content joined. REFACTORED: Added event_date, removed room_id and object fields';

-- View: Latency analysis with request/response timing
-- LATENCY: Comprehensive latency analysis view
CREATE OR REPLACE VIEW v_latency_analysis AS
SELECT 
    um.session_id,
    um.thread_id,
    um.event_date,
    um.model,
    um.request_timestamp,
    um.response_timestamp,
    -- Calculated latency
    EXTRACT(EPOCH FROM (um.response_timestamp - um.request_timestamp)) * 1000 AS calculated_latency_ms,
    um.latency_ms AS reported_latency_ms,
    -- Time-of-day metrics
    EXTRACT(HOUR FROM um.request_timestamp) AS request_hour,
    EXTRACT(DOW FROM um.request_timestamp) AS request_day_of_week,
    -- Cost and token correlation
    um.total_cost,
    um.total_tokens,
    -- Session-level latency
    EXTRACT(EPOCH FROM (r.created_timestamp - cs.request_timestamp)) * 1000 AS session_latency_ms,
    -- Tool context
    tu.tool_type,
    -- Task completion context
    cs.task_completed,
    cs.task_completion_status
FROM usage_metrics um
LEFT JOIN chat_sessions cs ON um.session_id = cs.session_id
LEFT JOIN responses r ON cs.response_id = r.response_id
LEFT JOIN tool_usage tu ON um.session_id = tu.session_id 
    AND um.thread_id = tu.thread_id
WHERE um.request_timestamp IS NOT NULL 
    AND um.response_timestamp IS NOT NULL;

COMMENT ON VIEW v_latency_analysis IS 'Comprehensive latency analysis view with calculated latency, time-of-day patterns, and correlation with costs/tokens. LATENCY: Uses request/response timestamps for accurate latency calculation';
