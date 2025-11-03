-- ============================================
-- Phase 2 Tables (Future Enhancements)
-- ============================================

-- Goal 4 & 5: User Feedback (Likes/Dislikes) and Test Data Collection

-- user_feedback: System quality analysis via likes/dislikes
CREATE TABLE user_feedback (
    feedback_id BIGINT IDENTITY(1,1),
    session_id VARCHAR(255) NOT NULL,
    thread_id VARCHAR(255) NOT NULL,
    user_id VARCHAR(255),
    feedback_type VARCHAR(20) NOT NULL, -- 'like', 'dislike', 'neutral'
    feedback_timestamp TIMESTAMP NOT NULL,
    response_id VARCHAR(255), -- FK to responses table
    feedback_reason TEXT, -- Optional reason for feedback
    insert_timestamp TIMESTAMP DEFAULT GETDATE(),
    
    DISTKEY(session_id),
    SORTKEY(feedback_timestamp, thread_id)
)
ENCODE AUTO;

COMMENT ON TABLE user_feedback IS 'User feedback (likes/dislikes) for system quality analysis (Goal 4). DISTKEY: session_id';

-- test_data_collection: Store liked responses for training data
CREATE TABLE test_data_collection (
    test_data_id BIGINT IDENTITY(1,1),
    session_id VARCHAR(255) NOT NULL,
    thread_id VARCHAR(255) NOT NULL,
    response_id VARCHAR(255) NOT NULL, -- FK to responses table
    feedback_id BIGINT NOT NULL, -- Link to user_feedback
    response_content TEXT, -- Snapshot of response content at feedback time (may reference responses table)
    reasoning_steps JSON, -- JSON of reasoning steps (snapshot)
    usage_metrics_id BIGINT, -- Link to usage_metrics
    model VARCHAR(100),
    created_timestamp TIMESTAMP,
    insert_timestamp TIMESTAMP DEFAULT GETDATE(),
    
    DISTKEY(session_id),
    SORTKEY(created_timestamp, thread_id)
)
ENCODE AUTO;

COMMENT ON TABLE test_data_collection IS 'Liked responses collected for test data (Goal 5). DISTKEY: session_id. response_id references responses table. response_content is a snapshot for training data preservation.';

-- Goal 6: Long-term Memory and Personalization

-- user_profiles: User personalization data
CREATE TABLE user_profiles (
    user_id VARCHAR(255) NOT NULL,
    thread_id VARCHAR(255) NOT NULL,
    profile_data JSON, -- Flexible JSON for various profile attributes
    preferences JSON, -- User preferences
    created_timestamp TIMESTAMP DEFAULT GETDATE(),
    updated_timestamp TIMESTAMP DEFAULT GETDATE(),
    
    DISTKEY(user_id),
    SORTKEY(user_id, updated_timestamp)
)
ENCODE AUTO;

COMMENT ON TABLE user_profiles IS 'User profiles for personalization (Goal 6)';

-- session_context: Context storage for AI agent
CREATE TABLE session_context (
    context_id BIGINT IDENTITY(1,1),
    session_id VARCHAR(255) NOT NULL,
    thread_id VARCHAR(255) NOT NULL,
    context_type VARCHAR(100), -- 'research', 'conversation', 'task', etc.
    context_data TEXT,
    context_metadata JSON,
    created_timestamp TIMESTAMP DEFAULT GETDATE(),
    expires_timestamp TIMESTAMP,
    
    DISTKEY(thread_id),
    SORTKEY(thread_id, created_timestamp)
)
ENCODE AUTO;

COMMENT ON TABLE session_context IS 'Context storage for AI agent long-term memory (Goal 6)';

-- bookmarks: User bookmarks
CREATE TABLE bookmarks (
    bookmark_id BIGINT IDENTITY(1,1),
    thread_id VARCHAR(255) NOT NULL,
    user_id VARCHAR(255),
    bookmark_title VARCHAR(500),
    bookmark_url VARCHAR(2000),
    bookmark_type VARCHAR(100), -- 'page', 'search', 'result', etc.
    created_timestamp TIMESTAMP DEFAULT GETDATE(),
    updated_timestamp TIMESTAMP DEFAULT GETDATE(),
    
    DISTKEY(thread_id),
    SORTKEY(thread_id, created_timestamp)
)
ENCODE AUTO;

COMMENT ON TABLE bookmarks IS 'User bookmarks (Goal 6)';

-- tab_groups: Tab grouping information
CREATE TABLE tab_groups (
    group_id BIGINT IDENTITY(1,1),
    thread_id VARCHAR(255) NOT NULL,
    user_id VARCHAR(255),
    group_name VARCHAR(255),
    group_type VARCHAR(100), -- 'grouped', 'ungrouped'
    tab_urls JSON, -- Array of URLs in the group
    created_timestamp TIMESTAMP DEFAULT GETDATE(),
    updated_timestamp TIMESTAMP DEFAULT GETDATE(),
    
    DISTKEY(thread_id),
    SORTKEY(thread_id, created_timestamp)
)
ENCODE AUTO;

COMMENT ON TABLE tab_groups IS 'Tab grouping/ungrouping information (Goal 6)';

-- research_sessions: Research-specific tracking
CREATE TABLE research_sessions (
    research_id BIGINT IDENTITY(1,1),
    session_id VARCHAR(255) NOT NULL,
    thread_id VARCHAR(255) NOT NULL,
    research_topic TEXT,
    research_keywords TEXT,
    citations JSON, -- Array of citations/URLs
    freshness_score INTEGER, -- How fresh the information is
    created_timestamp TIMESTAMP DEFAULT GETDATE(),
    
    DISTKEY(thread_id),
    SORTKEY(thread_id, created_timestamp)
)
ENCODE AUTO;

COMMENT ON TABLE research_sessions IS 'Research session tracking (Goal 6)';

-- interruptions: Track interruptions in sessions
CREATE TABLE interruptions (
    interruption_id BIGINT IDENTITY(1,1),
    session_id VARCHAR(255) NOT NULL,
    thread_id VARCHAR(255) NOT NULL,
    interruption_type VARCHAR(100), -- 'user_pause', 'timeout', 'error', etc.
    interruption_timestamp TIMESTAMP NOT NULL,
    interruption_reason TEXT,
    recovery_timestamp TIMESTAMP,
    
    DISTKEY(thread_id),
    SORTKEY(interruption_timestamp, thread_id)
)
ENCODE AUTO;

COMMENT ON TABLE interruptions IS 'Track interruptions in AI agent sessions (Goal 6)';

-- Materialized Views for Phase 2

-- mv_feedback_analytics: System quality based on feedback
-- BATCH: Manual refresh for non-real-time analytics
CREATE MATERIALIZED VIEW mv_feedback_analytics
BACKUP NO
AUTO REFRESH NO  -- Changed to NO for batch processing
AS
SELECT 
    DATE(feedback_timestamp) AS feedback_date,
    feedback_type,
    COUNT(*) AS feedback_count,
    COUNT(DISTINCT thread_id) AS unique_threads,
    COUNT(DISTINCT session_id) AS unique_sessions,
    COUNT(DISTINCT user_id) AS unique_users
FROM user_feedback
GROUP BY DATE(feedback_timestamp), feedback_type;

COMMENT ON MATERIALIZED VIEW mv_feedback_analytics IS 'Feedback analytics for system quality (Goal 4)';

-- mv_user_personalization_stats: User personalization metrics
-- BATCH: Manual refresh for non-real-time analytics
CREATE MATERIALIZED VIEW mv_user_personalization_stats
BACKUP NO
AUTO REFRESH NO  -- Changed to NO for batch processing
AS
SELECT 
    up.user_id,
    COUNT(DISTINCT up.thread_id) AS active_threads,
    COUNT(DISTINCT cs.session_id) AS total_sessions,
    SUM(COALESCE(um.total_tokens, 0)) AS total_tokens,
    SUM(COALESCE(um.total_cost, 0)) AS total_cost,
    MAX(cs.event_timestamp) AS last_activity
FROM user_profiles up
LEFT JOIN chat_sessions cs ON up.thread_id = cs.thread_id
LEFT JOIN usage_metrics um ON cs.session_id = um.session_id
GROUP BY up.user_id;

COMMENT ON MATERIALIZED VIEW mv_user_personalization_stats IS 'User personalization and activity statistics (Goal 6)';

