"""Signed sample uploads to the lab's local S3-compatible endpoint."""
import os
import sys
from uuid import uuid4

import boto3
from botocore import UNSIGNED
from botocore.config import Config
from botocore.exceptions import ClientError

ENDPOINT = "http://file-store:8333"
PAYLOAD = b"well_id,pressure_bar\nwell-17,210.5\n"


def client(unsigned=False):
    return boto3.client(
        "s3", endpoint_url=ENDPOINT, region_name="us-east-1",
        config=Config(
            signature_version=UNSIGNED if unsigned else "s3v4",
            s3={"addressing_style": "path"},
            request_checksum_calculation="when_required",
            response_checksum_validation="when_required",
            connect_timeout=3, read_timeout=4, retries={"total_max_attempts": 1},
        ),
    )


def main():
    action, *args = sys.argv[1:]
    store = client()
    bucket = os.environ["IMPORT_BUCKET"]
    if action == "seed":
        store.put_object(Bucket=bucket, Key="baseline.txt", Body=args[0].encode())
        return
    if action == "validate":
        response = store.get_object(Bucket=bucket, Key="baseline.txt")
        if response["Body"].read() != args[0].encode():
            sys.exit("FAIL: The original stored object is unavailable.")
        try:
            client(unsigned=True).get_object(Bucket=bucket, Key="baseline.txt")
        except ClientError as error:
            if error.response["ResponseMetadata"]["HTTPStatusCode"] not in (401, 403):
                raise
        else:
            sys.exit("FAIL: The original object must require authentication.")
    key = f"demo-checks/{uuid4().hex}.csv"
    store.put_object(Bucket=bucket, Key=key, Body=PAYLOAD)
    try:
        body = store.get_object(Bucket=bucket, Key=key)["Body"].read()
        if body != PAYLOAD:
            sys.exit("FAIL: Retrieved content differs from the sample.")
        print(f"PASS: Uploaded and read back {len(body)} bytes from {bucket}.")
    finally:
        store.delete_object(Bucket=bucket, Key=key)


if __name__ == "__main__":
    try:
        main()
    except ClientError as error:
        print(f"S3 request failed: {error.response['Error']['Code']}", file=sys.stderr)
        sys.exit(1)
