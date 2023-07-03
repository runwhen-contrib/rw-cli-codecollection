# AWS EKS Nodegroup Healthcheck
This codebundle queries the state of a nodegroup within a EKS cluster to check its state and raise issues if it's unhealthy.

## Tasks
`Check EKS Nodegroup Status`

## Configuration

The TaskSet requires initialization to import necessary secrets, services, and user variables. The following variables should be set:

- `aws_access_key_id`: the service account's access key ID, used during the `aws sts` call.
- `aws_secret_access_key`: The service account's secret access key, used during the `aws sts` call.
- `aws_role_arn`: The full aws role ARN that will be assumed.
- `aws_assume_role_name`: The name of the role to assume as part of the `aws sts` assume role call.
- `AWS_DEFAULT_REGION`: The AWS region to perform API requests in and for resources.
- `AWS_SERVICE`: The remote aws service to use for requests.
- `EKS_CLUSTER_NAME`: The name of the EKS cluster to query.
- `EKS_NODEGROUP`: The nodegroup within the cluster to check the status of.

## Notes

This codebundle assumes a traditional service account authentication using the assume role functionality of `aws sts`, and therefore a role with the correct access will be required so that it can be assumed by the service account for a temporary token.

## TODO
- [ ] Add documentation
- [ ] Look at dynamic/scaled nodegroup support