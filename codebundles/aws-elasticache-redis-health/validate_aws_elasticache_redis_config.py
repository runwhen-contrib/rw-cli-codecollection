import subprocess
import json
import os

# Environment Variables:
AWS_REGION = os.getenv("AWS_REGION")

# Execute AWS CLI command to get serverless caches
command = f"aws elasticache describe-serverless-caches --region {AWS_REGION}".split()
output = subprocess.run(command, capture_output=True, text=True)
if output.returncode != 0:
    print(f"Error: {output.stderr}")
    exit(1)
serverless_caches = json.loads(output.stdout)["ServerlessCaches"]

if not serverless_caches:
    print("No serverless caches found.")
    exit(0)

for cache in serverless_caches:
    arn = cache["ARN"]
    cache_name = cache["ServerlessCacheName"]
    status = cache["Status"]
    version = cache["FullEngineVersion"]
    cluster_read_endpoint = cache["ReaderEndpoint"]["Address"]
    cluster_read_port = cache["ReaderEndpoint"]["Port"]
    snapshot_limit = cache["SnapshotRetentionLimit"]
    issue_snapshot_zero = ""
    if snapshot_limit == 0:
        issue_snapshot_zero = "Error: Snapshot retention limit is set to 0"
    issue_status = ""
    if status != "available":
        issue_status = f"Error: Status {status} is not available"

    print("-------------------")
    print(f"ARN: {arn}")
    print(f"Serverless Cache Name: {cache_name}")
    print(f"Status: {status}")
    print(f"Port: {cluster_read_port}")
    print(f"Version: {version}")
    print(f"Endpoint: {cluster_read_endpoint}")
    print(f"Snapshot Limit: {snapshot_limit}")
    if issue_snapshot_zero:
        print(issue_snapshot_zero)
    if issue_status:
        print(issue_status)
    print("-------------------")
    print("")
