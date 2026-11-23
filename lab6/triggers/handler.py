import json
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)


def handler(event, context):
    """Handler for an Object Storage trigger.

    event["messages"] is a batch of object events; each message has
    event_metadata and details (bucket_id, object_id, event_type, ...).
    """
    logger.info("Raw event: %s", json.dumps(event, ensure_ascii=False))

    messages = event.get("messages", [])
    processed = []

    for message in messages:
        details = message.get("details", {})
        processed.append(
            {
                "bucket_id": details.get("bucket_id"),
                "object_id": details.get("object_id"),
                "event_type": details.get("event_type"),
                "size": details.get("object_size"),
            }
        )
        logger.info(
            "Object event: bucket=%s object=%s type=%s",
            details.get("bucket_id"),
            details.get("object_id"),
            details.get("event_type"),
        )

    return {
        "statusCode": 200,
        "body": {"processed": len(processed), "objects": processed},
    }
