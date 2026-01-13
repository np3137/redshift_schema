"""
Simple Iceberg ETL DAG for POC
This DAG demonstrates aggregating from Bronze (Iceberg) to Silver (Iceberg) to Gold (Iceberg)
"""

from airflow import DAG
from airflow.providers.amazon.aws.operators.athena import AthenaOperator
from airflow.utils.dates import days_ago
from datetime import timedelta

# ============================================
# CONFIGURATION - UPDATE THESE VALUES
# ============================================
ANALYTICS_BUCKET = 'your-analytics-bucket-name'  # CHANGE THIS
DATABASE = 'iceberg_poc'  # CHANGE THIS if needed
OUTPUT_LOCATION = f's3://{ANALYTICS_BUCKET}/athena-results/'

# ============================================
# DEFAULT ARGUMENTS
# ============================================
default_args = {
    'owner': 'data-engineering',
    'depends_on_past': False,
    'start_date': days_ago(1),
    'email_on_failure': False,
    'email_on_retry': False,
    'retries': 1,
    'retry_delay': timedelta(minutes=5),
}

# ============================================
# DAG DEFINITION
# ============================================
dag = DAG(
    'simple_iceberg_etl_poc',
    default_args=default_args,
    description='Simple POC: Bronze (Iceberg) → Silver (Iceberg) → Gold (Iceberg)',
    schedule_interval=None,  # Manual trigger for POC
    catchup=False,
    tags=['poc', 'iceberg', 'etl', 'simple'],
)

# ============================================
# TASK 1: CREATE SILVER TABLE
# ============================================
create_silver_table = AthenaOperator(
    task_id='create_silver_table',
    query=f"""
    CREATE TABLE IF NOT EXISTS {DATABASE}.silver_user_daily (
        dt DATE,
        platform STRING,
        user_id STRING,
        messages_cnt BIGINT,
        rooms_cnt BIGINT,
        tokens BIGINT,
        cost DECIMAL(10,4)
    )
    USING ICEBERG
    PARTITIONED BY (dt)
    LOCATION 's3://{ANALYTICS_BUCKET}/silver/silver_user_daily'
    TBLPROPERTIES (
        'write.target-file-size-bytes'='134217728',
        'write.parquet.compression-codec'='snappy'
    );
    """,
    database=DATABASE,
    output_location=OUTPUT_LOCATION,
    aws_conn_id='aws_default',
    dag=dag,
)

# ============================================
# TASK 2: AGGREGATE BRONZE → SILVER
# ============================================
aggregate_bronze_to_silver = AthenaOperator(
    task_id='aggregate_bronze_to_silver',
    query=f"""
    INSERT INTO {DATABASE}.silver_user_daily
    SELECT 
        dt,
        platform,
        user_id,
        COUNT(DISTINCT chat_id) as messages_cnt,
        COUNT(DISTINCT room_id) as rooms_cnt,
        SUM(tokens) as tokens,
        SUM(cost) as cost
    FROM {DATABASE}.bronze_chat_events
    WHERE dt = DATE '{{{{ ds }}}}'
    GROUP BY dt, platform, user_id;
    """,
    database=DATABASE,
    output_location=OUTPUT_LOCATION,
    aws_conn_id='aws_default',
    dag=dag,
)

# ============================================
# TASK 3: CREATE GOLD TABLE
# ============================================
create_gold_table = AthenaOperator(
    task_id='create_gold_table',
    query=f"""
    CREATE TABLE IF NOT EXISTS {DATABASE}.gold_time_series (
        grain STRING,
        period_start DATE,
        platform STRING,
        active_users BIGINT,
        total_messages BIGINT,
        total_tokens BIGINT,
        total_cost DECIMAL(10,4)
    )
    USING ICEBERG
    PARTITIONED BY (grain, period_start)
    LOCATION 's3://{ANALYTICS_BUCKET}/gold/gold_time_series'
    TBLPROPERTIES (
        'write.target-file-size-bytes'='134217728',
        'write.parquet.compression-codec'='snappy'
    );
    """,
    database=DATABASE,
    output_location=OUTPUT_LOCATION,
    aws_conn_id='aws_default',
    dag=dag,
)

# ============================================
# TASK 4: AGGREGATE SILVER → GOLD
# ============================================
aggregate_silver_to_gold = AthenaOperator(
    task_id='aggregate_silver_to_gold',
    query=f"""
    INSERT INTO {DATABASE}.gold_time_series
    SELECT 
        'DAILY' as grain,
        dt as period_start,
        platform,
        COUNT(DISTINCT user_id) as active_users,
        SUM(messages_cnt) as total_messages,
        SUM(tokens) as total_tokens,
        SUM(cost) as total_cost
    FROM {DATABASE}.silver_user_daily
    WHERE dt = DATE '{{{{ ds }}}}'
    GROUP BY dt, platform;
    """,
    database=DATABASE,
    output_location=OUTPUT_LOCATION,
    aws_conn_id='aws_default',
    dag=dag,
)

# ============================================
# TASK 5: VERIFY RESULTS
# ============================================
verify_results = AthenaOperator(
    task_id='verify_results',
    query=f"""
    SELECT 
        'Gold Data' as layer,
        COUNT(*) as row_count,
        SUM(active_users) as total_active_users,
        SUM(total_messages) as total_messages,
        SUM(total_tokens) as total_tokens
    FROM {DATABASE}.gold_time_series
    WHERE grain = 'DAILY' AND period_start = DATE '{{{{ ds }}}}';
    """,
    database=DATABASE,
    output_location=OUTPUT_LOCATION,
    aws_conn_id='aws_default',
    dag=dag,
)

# ============================================
# TASK DEPENDENCIES
# ============================================
# Flow: Create tables → Aggregate Bronze to Silver → Aggregate Silver to Gold → Verify
[create_silver_table, create_gold_table] >> aggregate_bronze_to_silver >> aggregate_silver_to_gold >> verify_results
