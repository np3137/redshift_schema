
from __future__ import annotations

import json
import logging
import time

import boto3
import pendulum
from airflow.models.dag import DAG
from airflow.operators.python import PythonOperator
from aws_msk_iam_sasl_signer import MSKAuthTokenProvider
from kafka import KafkaConsumer
from kafka.errors import KafkaError
from kafka.sasl.oauth import AbstractTokenProvider

log = logging.getLogger(__name__)

DEFAULT_ARGS = {
    "retries": 2,
    "retry_delay": pendulum.duration(minutes=5),
}


class AthenaAnalyticsTokenProvider(AbstractTokenProvider):
    """
    Token provider for MSK IAM (OAUTHBEARER) auth using the worker's IAM role.
    """

    def __init__(self, aws_region: str) -> None:
        self.aws_region = aws_region

    def token(self) -> str:
        auth_token, _expiry_ms = MSKAuthTokenProvider.generate_auth_token(self.aws_region)
        return auth_token


def consume_messages_from_msk(**context) -> list[dict]:
    """
    Consume messages from MSK in batches and return batch metadata + payloads.
    """
    conf = context["dag_run"].conf
    bootstrap_servers = conf.get("msk_bootstrap_servers")
    topic_name = conf.get("msk_topic_name", "athena-user-right-request-v0")
    consumer_group_id = conf.get("athena_analytics_group_id", "athena_analytics_group")
    max_messages = int(conf.get("max_messages", 10000))
    timeout_ms = int(conf.get("timeout_ms", 30000))
    auto_offset_reset = conf.get("auto_offset_reset", "earliest")
    batch_size = int(conf.get("batch_size", 100))
    aws_region = conf.get("aws_region", "ap-northeast-2")

    if not bootstrap_servers:
        raise ValueError(
            "msk_bootstrap_servers is required in DAG configuration. "
            "Please provide the MSK bootstrap servers."
        )
    if not topic_name:
        raise ValueError(
            "msk_topic_name is required in DAG configuration. "
            "Please provide the MSK topic name."
        )

    log.info(
        "Consuming messages from MSK. Bootstrap servers: %s, Topic: %s",
        bootstrap_servers,
        topic_name,
    )
    log.info(
        "Consumer config. Group ID: %s, Max messages: %s, Batch size: %s, Timeout: %sms",
        consumer_group_id,
        max_messages,
        batch_size,
        timeout_ms,
    )

    consumer = None
    consumed_batches: list[dict] = []
    total_successful_messages = 0

    try:
        consumer = KafkaConsumer(
            topic_name,
            bootstrap_servers=bootstrap_servers,
            group_id=consumer_group_id,
            auto_offset_reset=auto_offset_reset,
            enable_auto_commit=False,
            value_deserializer=lambda x: x.decode("utf-8") if x else None,
            key_deserializer=lambda x: x.decode("utf-8") if x else None,
            consumer_timeout_ms=timeout_ms,
            security_protocol="SASL_SSL",
            sasl_mechanism="OAUTHBEARER",
            sasl_oauth_token_provider=AthenaAnalyticsTokenProvider(aws_region),
            max_partition_fetch_bytes=10 * 1024 * 1024,
        )

        while total_successful_messages < max_messages:
            batch_start_time = time.time()
            batch_messages = []
            batch_partition_offsets: dict[int, int] = {}

            for message in consumer:
                if total_successful_messages >= max_messages:
                    break
                if not message.value:
                    continue

                try:
                    json_data = json.loads(message.value)
                except json.JSONDecodeError as exc:
                    log.warning("Failed to parse JSON message: %s", str(exc))
                    continue

                partition = message.partition
                offset = message.offset
                if partition not in batch_partition_offsets or offset > batch_partition_offsets[partition]:
                    batch_partition_offsets[partition] = offset

                batch_messages.append(
                    {
                        "json_data": json_data,
                        "partition": partition,
                        "offset": offset,
                        "key": message.key,
                        "timestamp": message.timestamp,
                    }
                )
                total_successful_messages += 1

                if len(batch_messages) >= batch_size:
                    break

            if not batch_messages:
                log.info("No more messages available in topic")
                break

            consumed_batches.append(
                {
                    "topic": topic_name,
                    "consumer_group_id": consumer_group_id,
                    "start_time": batch_start_time,
                    "end_time": time.time(),
                    "messages": batch_messages,
                    "partition_offsets": batch_partition_offsets,
                    "total_messages": len(batch_messages),
                    "processing_time": time.time() - batch_start_time,
                }
            )

            consumer.commit()
            log.info(
                "Committed offsets for batch of %s messages",
                len(batch_messages),
            )

        log.info(
            "Successfully consumed %s messages in %s batches from MSK topic %s",
            total_successful_messages,
            len(consumed_batches),
            topic_name,
        )
        return consumed_batches

    except KafkaError as exc:
        log.error("Kafka error while consuming from MSK: %s", str(exc))
        raise
    finally:
        if consumer:
            consumer.close()

def _extract_unique_guids(consumed_batches: list[dict]) -> list[str]:
    unique_guids: set[str] = set()
    for batch in consumed_batches:
        for message_info in batch.get("messages", []):
            json_obj = message_info.get("json_data", {})
            if not isinstance(json_obj, dict):
                continue
            if json_obj.get("right_type") != "ERASURE":
                continue
            guid = json_obj.get("guid")
            if guid:
                unique_guids.add(guid)
    return sorted(unique_guids)


def _run_athena_query(
    athena_client,
    query: str,
    database: str,
    output_location: str,
    poll_interval_seconds: int,
    timeout_seconds: int,
) -> str:
    response = athena_client.start_query_execution(
        QueryString=query,
        QueryExecutionContext={"Database": database},
        ResultConfiguration={"OutputLocation": output_location},
    )
    query_execution_id = response["QueryExecutionId"]
    start_time = time.time()

    while True:
        execution = athena_client.get_query_execution(QueryExecutionId=query_execution_id)
        state = execution["QueryExecution"]["Status"]["State"]
        if state in {"SUCCEEDED", "FAILED", "CANCELLED"}:
            break
        if time.time() - start_time > timeout_seconds:
            raise TimeoutError(f"Athena query timed out: {query_execution_id}")
        time.sleep(poll_interval_seconds)

    if state != "SUCCEEDED":
        reason = execution["QueryExecution"]["Status"].get("StateChangeReason", "Unknown")
        raise RuntimeError(f"Athena query failed ({state}): {reason}")

    return query_execution_id


def consume_and_delete_users(**context) -> dict:
    """
    Consume MSK messages in batches, extract GUIDs, and delete from Iceberg tables.
    """
    conf = context["dag_run"].conf
    aws_region = conf.get("aws_region", "ap-northeast-2")
    database_name = conf.get("iceberg_database", "iceberg_athena_analytics")
    output_location = conf.get("athena_s3_output", "s3://athena-query-results/")
    iceberg_table_s3_base = conf.get("iceberg_table_s3_base", "")
    user_id_column = conf.get("user_id_column", "user_id")
    poll_interval_seconds = int(conf.get("athena_poll_interval_seconds", 5))
    timeout_seconds = int(conf.get("athena_timeout_seconds", 3600))

    target_tables = conf.get("target_tables", ["silver_user_daily", "bronze_chat_events"])

    if iceberg_table_s3_base:
        log.info("Iceberg table S3 base location: %s", iceberg_table_s3_base)

    consumed_batches = consume_messages_from_msk(**context)
    guid_list = _extract_unique_guids(consumed_batches)

    if not guid_list:
        log.info("No GUIDs found in MSK batch; skipping deletes.")
        return {"deleted_tables": [], "guid_count": 0}

    guids_csv = ",".join(guid_list)
    athena_client = boto3.client("athena", region_name=aws_region)

    deleted_tables = []
    for table_name in target_tables:
        delete_sql = f"""
        DELETE FROM {database_name}.{table_name}
        WHERE {user_id_column} IN (
            SELECT guid
            FROM UNNEST(
                SPLIT(TRIM('{guids_csv}'), ',')
            ) AS t(guid)
            WHERE guid <> ''
        )
        """
        query_execution_id = _run_athena_query(
            athena_client=athena_client,
            query=delete_sql,
            database=database_name,
            output_location=output_location,
            poll_interval_seconds=poll_interval_seconds,
            timeout_seconds=timeout_seconds,
        )
        log.info("Deleted users from %s (query: %s)", table_name, query_execution_id)
        deleted_tables.append(table_name)

    return {"deleted_tables": deleted_tables, "guid_count": len(guid_list)}


with DAG(
    dag_id="user-deactivation-kafka-consume",
    start_date=pendulum.datetime(2023, 1, 1, tz="UTC"),
    catchup=False,
    schedule="@hourly",
    is_paused_upon_creation=False,
    tags=["msk", "kafka", "user-rights", "batch"],
    default_args=DEFAULT_ARGS,
) as dag:
    consume_and_delete_task = PythonOperator(
        task_id="consume_and_delete_users",
        python_callable=consume_and_delete_users,
    )