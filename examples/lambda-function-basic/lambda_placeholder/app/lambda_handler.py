"""Placeholder Lambda handler, replaced by the application's own deployment."""

import json


def handler(event, context):
    """Answer every invocation with 503 until real application code is deployed."""
    return {
        "statusCode": 503,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"detail": "Application code has not been deployed yet."}),
    }
