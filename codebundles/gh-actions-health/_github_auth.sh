#!/bin/bash
# Shared GitHub authentication helper
# Source this in any script: source "$(dirname "$0")/_github_auth.sh"
# Supports: GITHUB_TOKEN (PAT) or GITHUB_APP_ID + GITHUB_APP_PRIVATE_KEY (GitHub App with JWT)

set -e

function error_exit {
    echo "Error: $1" >&2
    exit 1
}

HEADERS=()
HEADERS+=(-H "Accept: application/vnd.github.v3+json")

setup_github_auth() {
    local app_id private_key client_id installation_id
    app_id=$(echo "$GITHUB_APP_ID" | tr -d '[:space:]')
    private_key="$GITHUB_APP_PRIVATE_KEY"
    client_id="$GITHUB_APP_CLIENT_ID"
    installation_id=$(echo "$GITHUB_APP_INSTALLATION_ID" | tr -d '[:space:]')

    if [ -n "$app_id" ] && [ -n "$private_key" ]; then
        local now iat exp header payload key_file signature jwt
        now=$(date +%s)
        iat=$((now - 60))
        exp=$((now + 540))
        header=$(printf '{"alg":"RS256","typ":"JWT"}' | base64 -w0 | tr '/+' '_-' | tr -d '=')
        payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$iat" "$exp" "$app_id" | base64 -w0 | tr '/+' '_-' | tr -d '=')
        key_file=$(mktemp)
        printf '%s' "$GITHUB_APP_PRIVATE_KEY" > "$key_file"
        chmod 600 "$key_file"
        signature=$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -sign "$key_file" -binary | base64 -w0 | tr '/+' '_-' | tr -d '=')
        rm -f "$key_file"
        jwt="$header.$payload.$signature"

        local installation_id="$GITHUB_APP_INSTALLATION_ID"
        if [ -z "$installation_id" ]; then
            local installations_response
            installations_response=$(curl -sS \
                -H "Authorization: Bearer $jwt" \
                -H "Accept: application/vnd.github.v3+json" \
                "https://api.github.com/app/installations")
            installation_id=$(echo "$installations_response" | jq -r '.[0].id')
            if [ -z "$installation_id" ] || [ "$installation_id" = "null" ]; then
                error_exit "Failed to discover GitHub App installation. Ensure the app is installed on an organization, or set GITHUB_APP_INSTALLATION_ID manually."
            fi
        fi

        local installation_token_response installation_token
        installation_token_response=$(curl -sS -X POST \
            -H "Authorization: Bearer $jwt" \
            -H "Accept: application/vnd.github.v3+json" \
            "https://api.github.com/app/installations/$installation_id/access_tokens")
        installation_token=$(echo "$installation_token_response" | jq -r '.token')
        if [ -z "$installation_token" ] || [ "$installation_token" = "null" ]; then
            error_exit "Failed to get GitHub App installation token"
        fi
        HEADERS+=(-H "Authorization: Bearer $installation_token")
    elif [ -n "$GITHUB_TOKEN" ]; then
        HEADERS+=(-H "Authorization: token $GITHUB_TOKEN")
    else
        error_exit "Either GITHUB_TOKEN or GitHub App credentials (GITHUB_APP_ID, GITHUB_APP_PRIVATE_KEY) are required"
    fi
}

function perform_curl {
    local url="$1"
    local response
    response=$(curl -sS "${HEADERS[@]}" "$url") || error_exit "Failed to perform curl request to $url"
    echo "$response"
}

function get_repositories_to_analyze {
    if [ "$GITHUB_REPOS" = "ALL" ]; then
        if [ -z "$GITHUB_ORGS" ]; then
            error_exit "GITHUB_ORGS is required when GITHUB_REPOS is 'ALL'"
        fi
        echo "Getting all repositories for organizations: $GITHUB_ORGS..." >&2
        all_repos=""
        IFS=',' read -ra ORG_ARRAY <<< "$GITHUB_ORGS"
        for org in "${ORG_ARRAY[@]}"; do
            org=$(echo "$org" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            if [ -n "$org" ]; then
                echo "Fetching repositories for organization: $org" >&2
                org_repos_json=$(perform_curl "https://api.github.com/orgs/$org/repos?per_page=100&sort=updated")
                if ! echo "$org_repos_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
                    echo "Failed to fetch repos for org $org or access denied — response was not an array. Skipping." >&2
                    continue
                fi
                if [ "${MAX_REPOS_PER_ORG:-0}" -gt 0 ]; then
                    org_repos=$(echo "$org_repos_json" | jq -r ".[0:${MAX_REPOS_PER_ORG}] | .[].full_name")
                else
                    org_repos=$(echo "$org_repos_json" | jq -r '.[].full_name')
                fi
                if [ -n "$all_repos" ]; then
                    all_repos="$all_repos"$'\n'"$org_repos"
                else
                    all_repos="$org_repos"
                fi
                sleep 0.5
            fi
        done
        if [ "${MAX_REPOS_TO_ANALYZE:-0}" -gt 0 ]; then
            echo "$all_repos" | head -n "${MAX_REPOS_TO_ANALYZE}"
        else
            echo "$all_repos"
        fi
    else
        echo "$GITHUB_REPOS" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
    fi
}

setup_github_auth