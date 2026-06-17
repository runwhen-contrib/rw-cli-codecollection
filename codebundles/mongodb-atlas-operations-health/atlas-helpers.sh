#!/usr/bin/env bash
# Shared Atlas Admin API helpers (digest auth, credential parsing).
# shellcheck shell=bash

ATLAS_API_ROOT="${ATLAS_API_ROOT:-https://cloud.mongodb.com/api/atlas/v2}"
ATLAS_ACCEPT="${ATLAS_ACCEPT:-application/vnd.atlas.2024-08-05+json}"

atlas_resolve_credentials() {
  if [[ -n "${ATLAS_PUBLIC_API_KEY:-}" && -n "${ATLAS_PRIVATE_API_KEY:-}" ]]; then
    return 0
  fi

  local raw=""
  raw="${ATLAS_API_KEY_CREDENTIALS:-}"
  if [[ -z "$raw" ]]; then
    raw="${atlas_api_key_credentials:-}"
  fi
  if [[ -z "$raw" ]]; then
    echo "atlas-helpers: set ATLAS_PUBLIC_API_KEY and ATLAS_PRIVATE_API_KEY, or provide atlas_api_key_credentials / ATLAS_API_KEY_CREDENTIALS (JSON or KEY=value lines)." >&2
    return 1
  fi

  if echo "$raw" | jq -e . >/dev/null 2>&1; then
    ATLAS_PUBLIC_API_KEY="$(echo "$raw" | jq -r '.ATLAS_PUBLIC_API_KEY // .publicKey // .username // empty')"
    ATLAS_PRIVATE_API_KEY="$(echo "$raw" | jq -r '.ATLAS_PRIVATE_API_KEY // .privateKey // .password // empty')"
  else
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ "$line" =~ ^[[:space:]]*# ]] && continue
      [[ -z "${line// /}" ]] && continue
      if [[ "$line" =~ ^ATLAS_PUBLIC_API_KEY[[:space:]]*=[[:space:]]*(.*)$ ]]; then
        ATLAS_PUBLIC_API_KEY="${BASH_REMATCH[1]}"
        ATLAS_PUBLIC_API_KEY="${ATLAS_PUBLIC_API_KEY%\"}"
        ATLAS_PUBLIC_API_KEY="${ATLAS_PUBLIC_API_KEY#\"}"
      fi
      if [[ "$line" =~ ^ATLAS_PRIVATE_API_KEY[[:space:]]*=[[:space:]]*(.*)$ ]]; then
        ATLAS_PRIVATE_API_KEY="${BASH_REMATCH[1]}"
        ATLAS_PRIVATE_API_KEY="${ATLAS_PRIVATE_API_KEY%\"}"
        ATLAS_PRIVATE_API_KEY="${ATLAS_PRIVATE_API_KEY#\"}"
      fi
    done <<< "$raw"
  fi

  if [[ -z "${ATLAS_PUBLIC_API_KEY:-}" || -z "${ATLAS_PRIVATE_API_KEY:-}" ]]; then
    echo "atlas-helpers: could not parse Atlas API keys from credentials payload." >&2
    return 1
  fi
  return 0
}

atlas_get() {
  local path_qs="$1"
  local outf code
  outf="$(mktemp)"
  code="$(
    curl -sS -o "$outf" -w "%{http_code}" \
      --digest \
      -u "${ATLAS_PUBLIC_API_KEY}:${ATLAS_PRIVATE_API_KEY}" \
      -H "Accept: ${ATLAS_ACCEPT}" \
      "${ATLAS_API_ROOT%/}/${path_qs#\/}" 2>/dev/null || echo "000"
  )"
  ATLAS_LAST_HTTP_CODE="$code"
  ATLAS_LAST_BODY="$(cat "$outf" 2>/dev/null || true)"
  rm -f "$outf"
}

cluster_matches_filter() {
  local cname="$1"
  local filt="${CLUSTER_FILTER:-}"
  filt="${filt//[[:space:]]/}"
  if [[ -z "$filt" ]]; then
    return 0
  fi
  local IFS=','; local tok
  for tok in $filt; do
    [[ -z "$tok" ]] && continue
    if [[ "$cname" == "$tok" ]]; then
      return 0
    fi
  done
  return 1
}
