#!/bin/bash
# AWS auth helper aligned with runwhen-local aws-auth template and runtime aws_utils.
# Supports: explicit keys, assume role, IRSA, pod identity, default credential chain.
#
# Usage: source this file, then call `auth`
#   source "$(dirname "$0")/auth.sh"
#   auth

_aws_verify() {
    aws sts get-caller-identity --output json >/dev/null 2>&1
}

auth() {
    if [[ -n "${AWS_WEB_IDENTITY_TOKEN_FILE:-}" ]] || [[ -n "${AWS_CONTAINER_CREDENTIALS_FULL_URI:-}" ]]; then
        if _aws_verify; then
            return 0
        fi
        echo "AWS identity (IRSA/pod identity) present but get-caller-identity failed."
        exit 1
    fi

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

    if _aws_verify; then
        return 0
    fi

    echo "AWS credentials not configured. Set credentials via the platform aws-auth block (e.g. aws:access_key@cli, aws:irsa@cli, aws:default@cli)."
    exit 1
}
