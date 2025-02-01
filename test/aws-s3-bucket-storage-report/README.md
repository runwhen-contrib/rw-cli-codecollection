# aws-s3-bucket-storage-report CodeBundle
### Tags:`AWS`, `S3 Bucket`, `Storage Issue`
## CodeBundle Objective:
Outputs the current usage values of all S3 buckets in a given AWS region, and the number of objects stored in them.

## CodeBundle Inputs:

export AWS_REGION="PLACEHOLDER"
export AWS_ACCESS_KEY_ID="PLACEHOLDER"
export AWS_SECRET_ACCESS_KEY="PLACEHOLDER"


## CodeBundle Tasks:
### `Check AWS S3 Bucket Storage Utilization`
#### Tags:`Amazon Web Services`, `AWS S3`, `Bucket Storage`
### Task Documentation:
This script checks and displays the storage utilization of a specified AWS S3 bucket. It uses the AWS CLI to list all objects in the bucket recursively, displaying the results in a human-readable format and providing a summary of the total storage used.
#### Usage Example:
`./check_AWS_S3_bucket_storage_utilization.sh`
