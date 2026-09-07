import json


def handler(event, context):
    return {
        "statusCode": 503,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"detail": "Application code has not been deployed yet."}),
    }
