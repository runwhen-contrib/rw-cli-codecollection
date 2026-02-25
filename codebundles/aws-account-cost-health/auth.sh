#!/bin/bash
# AWS auth helper aligned with runwhen-local aws-auth template and runtime aws_utils.
# Supports: explicit keys, assume role, IRSA, pod identity, default credential chain.
# Credentials are injected by the platform from the aws-auth block; this script
# optionally assumes a role when AWS_ROLE_ARN is set with base credentials, then
# verifies authentication.
#
# Usage: source this file, then call `auth`
#   source "$(dirname "$0")/auth.sh"
#   auth

_aws_verify() {
    aws sts get-caller-identity --output json >/dev/null 2>&1
}

auth() {
    # IRSA or EKS Pod Identity: no access keys required; runtime sets AWS_WEB_IDENTITY_TOKEN_FILE
    # or AWS_CONTAINER_CREDENTIALS_FULL_URI. Just verify.
    if [[ -n "${AWS_WEB_IDENTITY_TOKEN_FILE:-}" ]] || [[ -n "${AWS_CONTAINER_CREDENTIALS_FULL_URI:-}" ]]; then
        if _aws_verify; then
            return 0
        fi
        echo "AWS identity (IRSA/pod identity) present but get-caller-identity failed."
        exit 1
    fi

    # Explicit credentials: if AWS_ROLE_ARN is set with base creds, assume the role
    if [[ -n "${AWS_ACCESS_KEY_ID:-}" && -n "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
        if [[ -n "${AWS_ROLE_ARN:-}" ]]; then
            sts_output=$(aws sts assume-role --role-arn "$AWS_ROLE_ARN" --role-session-name "AssumeRoleSession" --output json)
            AWS_ACCESS_KEY_ID=$(echo "$sts_output" | jq -r '.Credentials.AccessKeyId')
            AWS_SECRET_ACCESS_KEY=$(echo "$sts_output" | jq -r '.Credentials.SecretAccessKey')
            AWS_SESSION_TOKEN=$(echo "$sts_output" | jq -r '.Credentials.SessionToken')
            export AWS_ACCESS_KEY_ID
            export AWS_SECRET_ACCESS_KEY
            export AWS_SESSION_TOKEN
        fi
        if _aws_verify; then
            return 0
        fi
        echo "AWS credentials set but get-caller-identity failed."
        exit 1
    fi

    # Default credential chain (env, profile, instance metadata, etc.)
    if _aws_verify; then
        return 0
    fi

    echo "AWS credentials not configured. Set credentials via the platform aws-auth block (e.g. aws:access_key@cli, aws:irsa@cli, aws:default@cli)."
    exit 1
}
