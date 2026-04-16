#!/usr/bin/env bash
# Shared helpers for LiteLLM proxy Admin API calls (sourced by task scripts).
# Requires: curl, jq, python3

litellm_base_url() {
  local u="${PROXY_BASE_URL:?Must set PROXY_BASE_URL}"
  u="${u%/}"
  printf '%s' "$u"
}

litellm_master_token() {
  local t="${LITELLM_MASTER_KEY:-${litellm_master_key:-}}"
  if [[ -z "$t" ]]; then
    echo "litellm_master_key secret not set" >&2
    return 1
  fi
  printf '%s' "$t"
}

# Prints: START_DATE END_DATE (YYYY-MM-DD) for LiteLLM spend routes.
litellm_date_range() {
  python3 - <<'PY'
import os, re, datetime
w = os.environ.get("RW_LOOKBACK_WINDOW", "24h").strip()
now = datetime.datetime.utcnow()
end = now.date()
if m := re.match(r"^(\d+)h$", w, re.I):
    delta = datetime.timedelta(hours=int(m.group(1)))
elif m := re.match(r"^(\d+)d$", w, re.I):
    delta = datetime.timedelta(days=int(m.group(1)))
elif m := re.match(r"^(\d+)m$", w, re.I):
    delta = datetime.timedelta(minutes=int(m.group(1)))
else:
    delta = datetime.timedelta(hours=24)
start_dt = now - delta
start = start_dt.date()
print(start.isoformat(), end.isoformat())
PY
}

# GET path (path begins with /). Writes body to file, prints HTTP code to stdout.
litellm_get_file() {
  local path="$1"
  local out="$2"
  local base
  base="$(litellm_base_url)" || return 1
  local tok
  tok="$(litellm_master_token)" || return 1
  local url="${base}${path}"
  curl -sS --max-time 120 -o "$out" -w "%{http_code}" \
    -H "Authorization: Bearer ${tok}" \
    -H "Accept: application/json" \
    "$url"
}
