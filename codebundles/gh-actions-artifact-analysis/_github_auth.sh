#!/bin/bash
# Shared GitHub authentication helper
# Source this in any script: source "$(dirname "$0")/_github_auth.sh"
#
# Supports:
#   - GITHUB_TOKEN (PAT)
#   - GitHub App: GITHUB_APP_ID + GITHUB_APP_PRIVATE_KEY
#     * If GITHUB_APP_INSTALLATION_ID is set, that installation is used.
#     * If not set, ALL installations for the app are discovered and each
#       org/account gets its own installation token. Requests are routed to
#       the correct token based on the owner in the request URL, which makes
#       multi-organization scans possible with a single GitHub App.

set -e

function error_exit {
    echo "Error: $1" >&2
    exit 1
}

GITHUB_API="https://api.github.com"

HEADERS=()
HEADERS+=(-H "Accept: application/vnd.github.v3+json")

DEFAULT_AUTH_HEADER=""
APP_JWT=""
declare -A APP_INSTALLATION_TOKENS

function _build_app_jwt {
    local app_id="$1"
    local private_key="$2"
    local now iat exp header payload key_file signature
    now=$(date +%s)
    iat=$((now - 60))
    exp=$((now + 540))
    header=$(printf '{"alg":"RS256","typ":"JWT"}' | base64 -w0 | tr '/+' '_-' | tr -d '=')
    payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$iat" "$exp" "$app_id" | base64 -w0 | tr '/+' '_-' | tr -d '=')
    key_file=$(mktemp)
    printf '%s' "$private_key" > "$key_file"
    chmod 600 "$key_file"
    signature=$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -sign "$key_file" -binary | base64 -w0 | tr '/+' '_-' | tr -d '=')
    rm -f "$key_file"
    echo "$header.$payload.$signature"
}

function _installation_token_for_id {
    local installation_id="$1"
    curl -sS -X POST \
        -H "Authorization: Bearer $APP_JWT" \
        -H "Accept: application/vnd.github.v3+json" \
        "$GITHUB_API/app/installations/$installation_id/access_tokens" | jq -r '.token // empty'
}

function _build_installation_token_map {
    local installs
    installs=$(curl -sS \
        -H "Authorization: Bearer $APP_JWT" \
        -H "Accept: application/vnd.github.v3+json" \
        "$GITHUB_API/app/installations")
    if ! echo "$installs" | jq -e 'type == "array"' >/dev/null 2>&1; then
        return 1
    fi
    local row login id token
    while IFS= read -r row; do
        login=$(echo "$row" | jq -r '.account.login // empty')
        id=$(echo "$row" | jq -r '.id // empty')
        if [ -z "$login" ] || [ -z "$id" ]; then continue; fi
        token=$(_installation_token_for_id "$id")
        if [ -z "$token" ]; then continue; fi
        APP_INSTALLATION_TOKENS["$login"]="$token"
    done <<< "$(echo "$installs" | jq -c '.[]')"
}

function setup_github_auth {
    local app_id private_key
    app_id=$(echo "$GITHUB_APP_ID" | tr -d '[:space:]')
    private_key="$GITHUB_APP_PRIVATE_KEY"

    if [ -n "$app_id" ] && [ -n "$private_key" ]; then
        APP_JWT=$(_build_app_jwt "$app_id" "$private_key")

        local explicit_id
        explicit_id=$(echo "$GITHUB_APP_INSTALLATION_ID" | tr -d '[:space:]')
        if [ -n "$explicit_id" ]; then
            local token
            token=$(_installation_token_for_id "$explicit_id")
            if [ -z "$token" ]; then
                error_exit "Failed to get GitHub App installation token for installation $explicit_id"
            fi
            DEFAULT_AUTH_HEADER="Authorization: Bearer $token"
        else
            if ! _build_installation_token_map; then
                error_exit "Failed to list GitHub App installations for app $app_id"
            fi
            if [ "${#APP_INSTALLATION_TOKENS[@]}" -eq 0 ]; then
                error_exit "No GitHub App installations found. Install the app on at least one organization, or set GITHUB_APP_INSTALLATION_ID."
            fi
            local k
            for k in "${!APP_INSTALLATION_TOKENS[@]}"; do
                DEFAULT_AUTH_HEADER="Authorization: Bearer ${APP_INSTALLATION_TOKENS[$k]}"
                break
            done
        fi
        HEADERS+=(-H "$DEFAULT_AUTH_HEADER")
    elif [ -n "$GITHUB_TOKEN" ]; then
        DEFAULT_AUTH_HEADER="Authorization: token $GITHUB_TOKEN"
        HEADERS+=(-H "$DEFAULT_AUTH_HEADER")
    else
        error_exit "Either GITHUB_TOKEN or GitHub App credentials (GITHUB_APP_ID, GITHUB_APP_PRIVATE_KEY) are required"
    fi
}

# Returns the auth header appropriate for a given API URL's owner.
function _auth_header_for_url {
    local url="$1"
    if [[ "$url" =~ ^https://api\.github\.com/(orgs|repos|users)/([^/?]+) ]]; then
        local owner="${BASH_REMATCH[2]}"
        local token="${APP_INSTALLATION_TOKENS[$owner]:-}"
        if [ -n "$token" ]; then
            echo "Authorization: Bearer $token"
            return
        fi
    fi
    echo "$DEFAULT_AUTH_HEADER"
}

# Curl helper that routes to the correct installation token based on URL owner.
# Usage: github_curl_url <url> [additional curl args...]
function github_curl_url {
    local url="$1"
    shift
    local auth
    auth=$(_auth_header_for_url "$url")
    if [ -n "$auth" ]; then
        curl -sS -H "Accept: application/vnd.github.v3+json" -H "$auth" "$@" "$url"
    else
        curl -sS -H "Accept: application/vnd.github.v3+json" "$@" "$url"
    fi
}

function perform_curl {
    github_curl_url "$1"
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
                org_repos_json=$(perform_curl "$GITHUB_API/orgs/$org/repos?per_page=100&sort=updated")
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