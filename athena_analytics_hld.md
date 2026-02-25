# Athena Analytics - High Level Design (HLD)

## Document Information

- **Project**: Athena Analytics Data Pipeline
- **Version**: 1.0
- **Last Updated**: 2026-02-25
- **Author**: Analytics Team

---

## Table of Contents

1. [System Overview](#system-overview)
2. [Architecture](#architecture)
3. [Components](#components)
4. [Data Flow](#data-flow)
5. [Data Model](#data-model)
6. [User Rights Management](#user-rights-management)
7. [Maintenance & Operations](#maintenance--operations)
8. [Security](#security)
9. [Performance](#performance)
10. [Monitoring](#monitoring)

---

## System Overview

### Purpose
The Athena Analytics system provides user behavior analytics for the internet browser product, processing chat events, user activities, and supporting user data rights management (GDPR compliance).

### Key Features
- Real-time chat event ingestion and analytics
- Daily/weekly/monthly user activity aggregation
- User data access, deletion, and service withdrawal
- Iceberg-based data lake with time travel capabilities
- Automated data maintenance and optimization

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                           ATHENA ANALYTICS SYSTEM                              │
├─────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                │
│  ┌──────────────┐     ┌──────────────┐     ┌──────────────┐     ┌──────────────┐  │
│  │   Browser    │────▶│     MSK      │────▶│   Airflow    │────▶│   Athena     │  │
│  │   (Source)   │     │  (Kafka)     │     │  (Orchestr. )│     │  (Query Eng.) │  │
│  └──────────────┘     └──────────────┘     └──────────────┘     └──────────────┘  │
│                                │                                       │           │
│                                │                                       ▼           │
│                                │                            ┌──────────────┐  │
│                                │                            │  AWS Glue   │  │
│                                │                            │ (Metastore) │  │
│                                │                            └──────────────┘  │
│                                │                                       │           │
│                                ▼                                       ▼           │
│                       ┌─────────────────────────────────────────────────────┐   │
│                       │            AWS S3 Data Lake                   │   │
│                       │  ┌───────────────────────────────────────────┐   │   │
│                       │  │         Iceberg Tables                    │   │   │
│                       │  │                                           │   │   │
│                       │  │  Bronze Layer (Raw Events)              │   │   │
│                       │  │  ├─ bronze_chat_events                 │   │   │
│                       │  │  ├─ bronze_reasoning_steps             │   │   │
│                       │  │                                           │   │   │
│                       │  │  Silver Layer (Aggregated)             │   │   │
│                       │  │  ├─ silver_user_daily                  │   │   │
│                       │  │  ├─ silver_room_daily                  │   │   │
│                       │  │  ├─ silver_message_daily                │   │   │
│                       │  │  ├─ silver_active_user_setting_daily    │   │   │
│                       │  │                                           │   │   │
│                       │  │  Gold Layer (Analytics)                │   │   │
│                       │  │  ├─ gold_time_series                   │   │   │
│                       │  │  ├─ gold_active_user_breakdown         │   │   │
│                       │  │  └─ gold_tool_call_breakdown            │   │   │
│                       │  └───────────────────────────────────────────┘   │   │
│                       └─────────────────────────────────────────────────────┘   │
│                                                                                │
│  ┌──────────────┐     ┌──────────────┐     ┌──────────────┐                │
│  │  MSK Topic   │◀────│  MSK Topic   │◀────│  MSK Topic   │                │
│  │  (Requests)  │     │  (Results)   │     │  (Events)    │                │
│  └──────────────┘     └──────────────┘     └──────────────┘                │
│                                                                                │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Components

### 1. Data Ingestion Layer

#### MSK (Amazon Managed Streaming for Kafka)
- **Purpose**: Real-time event streaming
- **Topics**:
  - `athena-user-right-request-v0`: User rights requests (ACCESS, ERASURE, SA_WITHDRAW)
  - `athena-user-right-request-result-v0`: Processing results
  - Chat events topic (for browser analytics)

### 2. Orchestration Layer

#### Apache Airflow
- **Purpose**: Workflow orchestration and scheduling
- **DAGs**:
  - `athena_analytics_etl`: Main ETL pipeline (hourly)
  - `athena_analytics_silver_daily_dag`: Daily aggregations
  - `athena_analytics_silver_weekly_dag`: Weekly aggregations
  - `athena_analytics_silver_monthly_dag`: Monthly aggregations
  - `athena_analytics_gold_daily_dag`: Gold layer daily
  - `athena_analytics_gold_weekly_dag`: Gold layer weekly
  - `athena_analytics_gold_monthly_dag`: Gold layer monthly
  - `athena_analytics_user_deactivation`: User rights management (hourly)
  - `athena_analytics_iceberg_maintenance`: Iceberg maintenance (daily)
  - `athena_analytics_metadata_cleanup_dag`: Metadata cleanup (daily)

### 3. Query Engine

#### Amazon Athena
- **Purpose**: SQL query engine over S3 data
- **Format**: Iceberg tables
- **Output**: S3 location for query results

### 4. Metadata Layer

#### AWS Glue Data Catalog
- **Purpose**: Table metadata and schema management
- **Integration**: Athena queries Iceberg tables via Glue

### 5. Storage Layer

#### Amazon S3
- **Purpose**: Data lake storage
- **Format**: Parquet files (columnar, compressed)
- **Table Format**: Apache Iceberg (ACID, time travel)

---

## Data Flow

### 1. Event Ingestion Flow

```
Browser Event
    │
    ▼
┌──────────┐
│   MSK    │ (Chat Events Topic)
│  (Kafka) │
└──────────┘
    │
    ▼
┌─────────────────────────────────────┐
│    Airflow ETL DAG                │
│  (athena_analytics_etl)           │
│  - Runs hourly                      │
└─────────────────────────────────────┘
    │
    ├──► bronze_chat_events (INSERT)
    │     Raw event data
    │
    └──► bronze_reasoning_steps (INSERT)
          Reasoning step data
```

### 2. Aggregation Flow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        Bronze Layer (Raw)                                    │
│  ┌─────────────────────┐  ┌─────────────────────┐                         │
│  │ bronze_chat_events  │  │bronze_reasoning_steps│                         │
│  └──────────┬──────────┘  └──────────┬──────────┘                         │
│             │                        │                                      │
└─────────────┼────────────────────────┼──────────────────────────────────────┘
              │                        │
              ▼                        ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                      Silver Layer (Aggregated)                              │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │  Daily Aggregations (athena_analytics_silver_daily_dag)              │  │
│  │  ├─ silver_user_daily                                               │  │
│  │  ├─ silver_room_daily                                               │  │
│  │  └─ silver_message_daily                                            │  │
│  │                                                                    │  │
│  │  Weekly Aggregations (athena_analytics_silver_weekly_dag)            │  │
│  │  └─ silver_active_user_setting_daily                                 │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
              │
              ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                       Gold Layer (Analytics)                                 │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │  Time Series Analytics                                               │  │
│  │  └─ gold_time_series                                                 │  │
│  │                                                                    │  │
│  │  User Breakdown                                                     │  │
│  │  └─ gold_active_user_breakdown                                       │  │
│  │                                                                    │  │
│  │  Tool Usage                                                         │  │
│  │  └─ gold_tool_call_breakdown                                          │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 3. User Rights Management Flow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                     User Rights Request Flow                                 │
└─────────────────────────────────────────────────────────────────────────────┘

User Request
    │
    │ (ERASURE | SA_WITHDRAW | ACCESS)
    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                    MSK Topic                                                 │
│          athena-user-right-request-v0                                       │
└─────────────────────────────────────────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│             Airflow DAG: athena_analytics_user_deactivation                  │
│  - Consumes messages one-by-one                                           │
│  - Processes up to 500 messages per run                                  │
│  - Runs hourly                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
    │
    ├──► Check if user exists in tables
    │     - Query: EXISTS in silver_user_daily
    │     - Result: True/False
    │
    ├──► [IF FALSE] ──► Return 201 (No Data)
    │
    └──► [IF TRUE] ──► Process Request
        │
        ├──► [ERASURE | SA_WITHDRAW]
        │     │
        │     ├──► Get chat_ids from bronze_chat_events
        │     │
        │     ├──► Delete from 5 user_id tables:
        │     │     - bronze_chat_events
        │     │     - silver_user_daily
        │     │     - bronze_reasoning_steps
        │     │     - silver_active_user_setting_daily
        │     │     - silver_room_daily
        │     │
        │     └──► Delete from silver_message_daily (via chat_ids)
        │
        └──► [ACCESS]
              │
              └──► Export data from all tables to S3
                    - Save as CSV files
                    - Return S3 URLs as attachments
```

---

## Data Model

### Bronze Layer (Raw Events)

#### bronze_chat_events
```sql
CREATE TABLE iceberg_athena_analytics.bronze_chat_events (
    event_id STRING,
    user_id STRING,
    chat_id STRING,
    message STRING,
    tool_name STRING,
    created_at TIMESTAMP,
    partition_date DATE
)
PARTITIONED BY (partition_date)
LOCATION 's3://.../bronze_chat_events/'
TBLPROPERTIES (
    'table_type' = 'ICEBERG',
    'format_version' = '2'
)
```

#### bronze_reasoning_steps
```sql
CREATE TABLE iceberg_athena_analytics.bronze_reasoning_steps (
    event_id STRING,
    user_id STRING,
    reasoning_step STRING,
    step_details STRING,
    created_at TIMESTAMP,
    partition_date DATE
)
PARTITIONED BY (partition_date)
LOCATION 's3://.../bronze_reasoning_steps/'
TBLPROPERTIES (
    'table_type' = 'ICEBERG',
    'format_version' = '2'
)
```

### Silver Layer (Aggregated)

#### silver_user_daily
```sql
CREATE TABLE iceberg_athena_analytics.silver_user_daily (
    user_id STRING,
    date_col DATE,
    message_count INT,
    chat_count INT,
    tool_usage MAP<STRING, INT>,
    last_activity TIMESTAMP,
    updated_at TIMESTAMP
)
PARTITIONED BY (date_col)
LOCATION 's3://.../silver_user_daily/'
```

#### silver_room_daily
```sql
CREATE TABLE iceberg_athena_analytics.silver_room_daily (
    room_id STRING,
    date_col DATE,
    user_count INT,
    message_count INT,
    created_at TIMESTAMP
)
PARTITIONED BY (date_col)
```

#### silver_message_daily
```sql
CREATE TABLE iceberg_athena_analytics.silver_message_daily (
    chat_id STRING,
    date_col DATE,
    user_id STRING,
    message_count INT,
    updated_at TIMESTAMP
)
PARTITIONED BY (date_col)
```

### Gold Layer (Analytics)

#### gold_time_series
```sql
CREATE TABLE iceberg_athena_analytics.gold_time_series (
    date_col DATE,
    total_users INT,
    active_users INT,
    total_messages INT,
    unique_chats INT,
    avg_messages_per_user DOUBLE
)
PARTITIONED BY (date_col)
```

---

## User Rights Management

### Supported Request Types

#### 1. ACCESS Request
- **Purpose**: Export user data for data access requests
- **Process**:
  1. Check if user exists
  2. Export data from all tables to CSV
  3. Upload CSVs to S3
  4. Return S3 URLs as attachments
- **Response**: 200 (Success) with attachments or 500 (Error)

#### 2. ERASURE Request
- **Purpose**: Delete all user data (right to be forgotten)
- **Process**:
  1. Check if user exists
  2. Delete from all user_id-based tables
  3. Get chat_ids and delete from silver_message_daily
  4. Return 200 (Success) or 201 (No Data) or 500 (Error)

#### 3. SA_WITHDRAW Request
- **Purpose**: Service withdrawal (similar to erasure)
- **Process**: Same as ERASURE request
- **Response**: Same as ERASURE request

### Request/Response Format

#### Request Message
```json
{
  "request_id": "unique-request-id",
  "guid": "user-identifier",
  "right_type": "ACCESS|ERASURE|SA_WITHDRAW",
  "created_at": 1234567890
}
```

#### Response Message
```json
{
  "request_id": "unique-request-id",
  "guid": "user-identifier",
  "right_type": "ACCESS|ERASURE|SA_WITHDRAW",
  "service_name": "analytics",
  "result": {
    "code": "200|201|500",
    "reason": "Success|No Data|Error message",
    "attachments": ["s3://.../file1.csv", "s3://.../file2.csv"]
  },
  "created_at": 1234567890,
  "finished_at": 1234567999
}
```

---

## Maintenance & Operations

### 1. Iceberg Maintenance DAG

#### athena_analytics_iceberg_maintenance

**Schedule**: Daily

**Operations**:
- **Expire Snapshots**: Remove old snapshots
- **Rewrite Data**: Compact small files
- **Orphan File Cleanup**: Remove deleted files
- **Metadata Cleanup**: Remove orphaned metadata files

**Performance Metrics**:
- Snapshot count before/after
- Files deleted
- Data files rewritten
- Orphan files cleaned

### 2. Metadata Cleanup DAG

#### athena_analytics_metadata_cleanup_dag

**Schedule**: Daily

**Operations**:
- Remove orphaned metadata files
- Clean up metadata table

### 3. Vacuum Properties

All tables configured with vacuum properties:
```sql
TBLPROPERTIES (
    'vacuum_min_snapshots_to_keep' = '10',
    'vacuum_max_snapshot_age_seconds' = '2592000',
    'vacuum_enabled' = 'true'
)
```

---

## Security

### 1. IAM Authentication

#### MSK Access
- Uses SASL/IAM OAUTHBEARER authentication
- Token provider generates AWS IAM tokens
- Required permissions:
  - `kafka-cluster:Connect`
  - `kafka-cluster:ReadData`
  - `kafka-cluster:WriteData`
  - `kafka-cluster:DescribeTopic`
  - `kafka-cluster:DescribeGroup`
  - `kafka-cluster:AlterGroup`

#### Athena Access
- Full access to Athena and Glue
- S3 access for query results and data storage
- KMS access for encryption/decryption

### 2. Encryption
- **In Transit**: TLS between MSK and Airflow
- **At Rest**: S3 server-side encryption

### 3. Data Privacy
- User data deletion support (ERASURE)
- Data export for access requests (ACCESS)
- Service withdrawal support (SA_WITHDRAW)

---

## Performance

### Target Metrics

#### Throughput
- **Target**: 30,000 events/day
- **Required**: 1,250 messages/hour
- **Current**: ~20 messages/hour per DAG run
- **Scaling**: 24 hourly runs × 500 messages = 12,000 messages/day capacity

#### Optimization Strategies
1. **GUID Check Optimization**: Single table query instead of full scan
2. **Batch Processing**: Process up to 500 messages per DAG run
3. **Iceberg Optimization**: Bin pack compaction after deletions
4. **Partitioning**: Date-based partitioning for efficient querying

### Performance Monitoring

#### Key Metrics Tracked
- Per-message processing time (avg, min, max)
- GUID check time (avg)
- Deletion time (avg)
- Access time (avg)
- Throughput (messages/minute, messages/hour)
- Target comparison (✓ meets / ⚠ below)

---

## Monitoring

### 1. Airflow Metrics
- DAG run duration
- Task success/failure rates
- Task retry counts
- Backlog (unprocessed messages in MSK)

### 2. Athena Metrics
- Query execution time
- Query cost
- Failed queries
- Data scanned

### 3. MSK Metrics
- Consumer lag (offset lag)
- Messages consumed
- Messages produced
- Consumer group lag

### 4. S3 Metrics
- Storage usage
- Data transfer costs
- Request counts

### 5. Alert Thresholds
- DAG failure rate > 5%
- Query timeout rate > 1%
- Consumer lag > 1000 messages
- Throughput < 1,000 messages/hour

---

## Appendix

### A. Airflow Variables

| Variable Name | Default | Description |
|---------------|---------|-------------|
| `athena_cron_hourly_job` | - | Hourly schedule for ETL DAG |
| `msk_bootstrap_servers` | - | MSK bootstrap servers |
| `iceberg_msk_topic_name` | athena-user-right-request-v0 | MSK topic for user rights |
| `iceberg_msk_max_messages` | 500 | Max messages per DAG run |
| `iceberg_msk_timeout_ms` | 30000 | Timeout in milliseconds |
| `iceberg_aws_region` | ap-northeast-2 | AWS region |
| `iceberg_database` | iceberg_athena_analytics | Database name |
| `athena_s3_iceberg_output` | - | S3 location for Athena results |
| `iceberg_user_id_column` | user_id | User ID column name |
| `iceberg_user_id_key_tables` | bronze_chat_events,silver_user_daily,... | User ID tables |
| `iceberg_chat_id_key_tables` | silver_message_daily | Chat ID tables |
| `athena_user_access_output` | - | S3 location for user data exports |

### B. DAG Dependencies

```
athena_analytics_etl (hourly)
    ├──► bronze_chat_events (populated)
    ├──► bronze_reasoning_steps (populated)
    └──► Triggers silver_daily_dag

athena_analytics_silver_daily_dag (daily)
    ├──► silver_user_daily (updated)
    ├──► silver_room_daily (updated)
    └──► silver_message_daily (updated)
    └──► Triggers gold_daily_dag

athena_analytics_gold_daily_dag (daily)
    ├──► gold_time_series (updated)
    ├──► gold_active_user_breakdown (updated)
    └──► gold_tool_call_breakdown (updated)

athena_analytics_user_deactivation (hourly)
    └──► Processes user rights requests

athena_analytics_iceberg_maintenance (daily)
    └──► Optimizes all Iceberg tables
```

### C. Error Handling

#### User Deactivation DAG Error Codes

| Code | Meaning | Action |
|------|---------|--------|
| 200 | Success | Request completed successfully |
| 201 | No Data | User not found, no action taken |
| 500 | Error | Request failed, check logs |

#### Common Error Scenarios
1. **Athena Query Timeout**: Increase timeout or optimize query
2. **MSK Connection Error**: Check IAM permissions and network
3. **S3 Upload Error**: Check S3 permissions and bucket access
4. **Invalid GUID**: Skip message, continue processing
5. **Malformed JSON**: Log error, continue processing

---

## Version History

| Version | Date | Changes |
|---------|------|--------|
| 1.0 | 2026-02-25 | Initial HLD document |

---

## Glossary

- **Bronze Layer**: Raw, unprocessed data storage
- **Silver Layer**: Aggregated, processed data (daily/weekly/monthly)
- **Gold Layer**: Analytics-ready data for reporting
- **Iceberg**: Table format providing ACID transactions and time travel
- **MSK**: Amazon Managed Streaming for Kafka
- **DAG**: Directed Acyclic Graph (Airflow workflow)
- **ERASURE**: Right to be forgotten (delete user data)
- **SA_WITHDRAW**: Service withdrawal request
- **ACCESS**: Data access request (export user data)
- **GUID**: Globally Unique Identifier (user ID)
- **Snapshot**: Iceberg table state at a point in time
