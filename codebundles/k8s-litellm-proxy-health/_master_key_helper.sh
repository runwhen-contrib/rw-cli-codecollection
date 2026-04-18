#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Shared helper to resolve LITELLM_MASTER_KEY.
#
# Resolution order:
#   0. Cached key in LITELLM_MASTER_KEY_CACHE_FILE (default: ./.litellm_master_key).
#      This is what Suite Setup writes via resolve-litellm-master-key.sh so the
#      downstream per-task scripts don't re-run kubectl.
#   1. LITELLM_MASTER_KEY (env) already set -> use as-is.
#   2. litellm_master_key (RW secret env var) set -> use as-is, after trimming.
#      Robot's ${EMPTY} fallback passes an unusable string through the RW.CLI
#      secret__ kwarg, so we trim and treat sentinel values as unset.
#   3. LITELLM_MASTER_KEY_SECRET_NAME set -> read that Secret from $NAMESPACE,
#      preferring LITELLM_MASTER_KEY_SECRET_KEY, else default candidate keys.
#   4. Infer from the LiteLLM workload's Pod env vars. Uses LITELLM_SERVICE_NAME
#      to find the backing Pods, walks containers[].env[] for names matching
#      LITELLM_MASTER_KEY / MASTER_KEY / etc., and follows a valueFrom.secretKeyRef
#      (or uses a literal .value when present).
#   5. Exec fallback: `kubectl exec <pod> -- printenv <NAME>` for each candidate
#      env name. Works when we lack `get secret` RBAC or when the env var is
#      injected via envFrom.secretRef (not visible in the Pod spec).
#   6. Auto-discover: any Secret in $NAMESPACE whose name matches
#      LITELLM_MASTER_KEY_SECRET_PATTERN (default: "litellm") using the default
#      candidate keys.
#
# Required for steps 3-6: CONTEXT, NAMESPACE, and kubectl on PATH. Step 4 also
# needs LITELLM_SERVICE_NAME and jq. Step 5 needs exec permission on the Pod.
#
# Set LITELLM_MASTER_KEY_INFER_FROM_POD=false to skip steps 4 and 5.
# Set LITELLM_MASTER_KEY_EXEC_FALLBACK=false to skip only step 5.
#
# Exports LITELLM_MASTER_KEY on success. Leaves it empty and returns 0 if no
# key could be found, so callers can decide whether to warn or fail.
#
# Diagnostics are intentionally written to stdout (not stderr) so RW.CLI.Run
# Bash File surfaces them in task reports. The key value itself is never
# printed; only the source/secret/key it was derived from.
# -----------------------------------------------------------------------------

LITELLM_MASTER_KEY_CACHE_FILE="${LITELLM_MASTER_KEY_CACHE_FILE:-./.litellm_master_key}"

# Returns 0 and echoes the trimmed input if it represents a plausible non-empty
# master key (not empty, not whitespace, not the literal "${EMPTY}" sentinel).
_litellm_sanitize() {
  local raw="$1"
  raw="${raw#"${raw%%[![:space:]]*}"}"
  raw="${raw%"${raw##*[![:space:]]}"}"
  if [[ -z "$raw" || "$raw" == '${EMPTY}' || "$raw" == 'None' ]]; then
    return 1
  fi
  printf '%s' "$raw"
}

_LITELLM_MK_DEFAULT_KEYS=(
  masterkey
  master_key
  MASTER_KEY
  LITELLM_MASTER_KEY
  litellm_master_key
  api_key
  API_KEY
)

# Env-var names we recognize on the LiteLLM container when scanning pod spec.
_LITELLM_MK_ENV_NAMES=(
  LITELLM_MASTER_KEY
  MASTER_KEY
  PROXY_MASTER_KEY
  LITELLM_PROXY_MASTER_KEY
)

_litellm_read_secret_key() {
  local kbin="$1" ctx="$2" ns="$3" sname="$4" skey="$5"
  local raw
  raw=$("$kbin" --context "$ctx" -n "$ns" get secret "$sname" -o "jsonpath={.data.${skey}}" 2>/dev/null || echo "")
  if [[ -z "$raw" ]]; then
    return 1
  fi
  if command -v base64 >/dev/null 2>&1; then
    echo "$raw" | base64 -d 2>/dev/null
  else
    echo ""
  fi
}

_litellm_try_secret() {
  local kbin="$1" ctx="$2" ns="$3" sname="$4"
  local keys=()
  if [[ -n "${LITELLM_MASTER_KEY_SECRET_KEY:-}" ]]; then
    keys=("$LITELLM_MASTER_KEY_SECRET_KEY")
  else
    keys=("${_LITELLM_MK_DEFAULT_KEYS[@]}")
  fi
  local k val
  for k in "${keys[@]}"; do
    val=$(_litellm_read_secret_key "$kbin" "$ctx" "$ns" "$sname" "$k" || true)
    if [[ -n "$val" ]]; then
      export LITELLM_MASTER_KEY="$val"
      echo "Derived LiteLLM master key from secret ${sname} key ${k} in namespace ${ns}."
      return 0
    fi
  done
  return 1
}

# Finds pods backing LITELLM_SERVICE_NAME and emits a newline-separated list.
_litellm_find_pods() {
  local kbin="$1" ctx="$2" ns="$3" svc="$4"
  local selector
  selector=$("$kbin" --context "$ctx" -n "$ns" get svc "$svc" \
    -o jsonpath='{range .spec.selector}{.}{"\n"}{end}' 2>/dev/null || true)
  # Build a label selector "k1=v1,k2=v2" from the JSON selector map
  local sel_json
  sel_json=$("$kbin" --context "$ctx" -n "$ns" get svc "$svc" -o jsonpath='{.spec.selector}' 2>/dev/null || echo "")
  if [[ -z "$sel_json" || "$sel_json" == "map[]" ]]; then
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    return 1
  fi
  local label_selector
  label_selector=$("$kbin" --context "$ctx" -n "$ns" get svc "$svc" -o json 2>/dev/null \
    | jq -r '.spec.selector // {} | to_entries | map("\(.key)=\(.value)") | join(",")')
  if [[ -z "$label_selector" ]]; then
    return 1
  fi
  "$kbin" --context "$ctx" -n "$ns" get pods -l "$label_selector" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true
}

# Scans a pod's containers[].env[] for a LiteLLM master-key-ish variable and
# either prints the literal value or resolves it via secretKeyRef.
_litellm_try_pod_env() {
  local kbin="$1" ctx="$2" ns="$3" pod="$4"
  if ! command -v jq >/dev/null 2>&1; then
    return 1
  fi
  local pod_json
  pod_json=$("$kbin" --context "$ctx" -n "$ns" get pod "$pod" -o json 2>/dev/null || echo "")
  [[ -z "$pod_json" ]] && return 1

  local names_filter
  names_filter=$(printf '%s\n' "${_LITELLM_MK_ENV_NAMES[@]}" | jq -R . | jq -sc .)

  # Extract the first matching env entry across all containers.
  local entry
  entry=$(echo "$pod_json" | jq -c --argjson names "$names_filter" '
    [ .spec.containers[]?.env[]? | select(.name as $n | $names | index($n)) ][0] // empty
  ')
  if [[ -z "$entry" || "$entry" == "null" ]]; then
    return 1
  fi

  local name literal sref_name sref_key
  name=$(echo "$entry" | jq -r '.name // ""')
  literal=$(echo "$entry" | jq -r '.value // ""')
  sref_name=$(echo "$entry" | jq -r '.valueFrom.secretKeyRef.name // ""')
  sref_key=$(echo "$entry" | jq -r '.valueFrom.secretKeyRef.key // ""')

  if [[ -n "$literal" ]]; then
    export LITELLM_MASTER_KEY="$literal"
    echo "Derived LiteLLM master key from pod ${pod} env var ${name} (literal value)."
    return 0
  fi
  if [[ -n "$sref_name" && -n "$sref_key" ]]; then
    local val
    val=$(_litellm_read_secret_key "$kbin" "$ctx" "$ns" "$sref_name" "$sref_key" || true)
    if [[ -n "$val" ]]; then
      export LITELLM_MASTER_KEY="$val"
      echo "Derived LiteLLM master key from pod ${pod} env ${name} -> secret ${sref_name}[${sref_key}]."
      return 0
    fi
    echo "WARN: Pod ${pod} env ${name} references secret ${sref_name}[${sref_key}] but the Secret could not be read."
  fi
  return 1
}

_litellm_try_workload_env() {
  local kbin="$1" ctx="$2" ns="$3" svc="$4"
  if [[ -z "$svc" ]] || ! command -v jq >/dev/null 2>&1; then
    return 1
  fi
  local pods
  pods=$(_litellm_find_pods "$kbin" "$ctx" "$ns" "$svc" || true)
  if [[ -z "$pods" ]]; then
    return 1
  fi
  local p
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    if _litellm_try_pod_env "$kbin" "$ctx" "$ns" "$p"; then
      return 0
    fi
  done <<<"$pods"
  return 1
}

# Tries `kubectl exec <pod> -- printenv <NAME>` for each candidate env name.
# Falls back to `sh -c 'echo "$NAME"'` if printenv is missing in the image.
_litellm_try_pod_exec() {
  local kbin="$1" ctx="$2" ns="$3" pod="$4"
  local name val
  for name in "${_LITELLM_MK_ENV_NAMES[@]}"; do
    val=$("$kbin" --context "$ctx" -n "$ns" exec "$pod" -- printenv "$name" 2>/dev/null \
      | tr -d '\r\n' || true)
    if [[ -z "$val" ]]; then
      val=$("$kbin" --context "$ctx" -n "$ns" exec "$pod" -- sh -c "printf %s \"\${${name}:-}\"" 2>/dev/null \
        | tr -d '\r\n' || true)
    fi
    if [[ -n "$val" ]]; then
      export LITELLM_MASTER_KEY="$val"
      echo "Derived LiteLLM master key by exec-ing pod ${pod} and reading env ${name}."
      return 0
    fi
  done
  return 1
}

_litellm_try_workload_exec() {
  local kbin="$1" ctx="$2" ns="$3" svc="$4"
  if [[ -z "$svc" ]]; then
    return 1
  fi
  local pods
  pods=$(_litellm_find_pods "$kbin" "$ctx" "$ns" "$svc" || true)
  if [[ -z "$pods" ]]; then
    return 1
  fi
  local p
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    if _litellm_try_pod_exec "$kbin" "$ctx" "$ns" "$p"; then
      return 0
    fi
  done <<<"$pods"
  return 1
}

resolve_master_key() {
  # Step 0: reuse a cached resolution written by Suite Setup.
  if [[ -n "${LITELLM_MASTER_KEY_CACHE_FILE:-}" && -s "$LITELLM_MASTER_KEY_CACHE_FILE" ]]; then
    local cached
    cached=$(<"$LITELLM_MASTER_KEY_CACHE_FILE")
    if cached=$(_litellm_sanitize "$cached"); then
      export LITELLM_MASTER_KEY="$cached"
      echo "Using LiteLLM master key from cache file ${LITELLM_MASTER_KEY_CACHE_FILE}."
      return 0
    fi
  fi

  # Step 1: explicit env var.
  local sanitized
  if sanitized=$(_litellm_sanitize "${LITELLM_MASTER_KEY:-}"); then
    export LITELLM_MASTER_KEY="$sanitized"
    echo "Using LiteLLM master key from LITELLM_MASTER_KEY env."
    return 0
  fi

  # Step 2: RW.CLI secret injection (env var `litellm_master_key`).
  if sanitized=$(_litellm_sanitize "${litellm_master_key:-}"); then
    export LITELLM_MASTER_KEY="$sanitized"
    echo "Using LiteLLM master key from imported litellm_master_key secret."
    return 0
  fi

  local kbin="${KUBERNETES_DISTRIBUTION_BINARY:-kubectl}"
  local ctx="${CONTEXT:-}"
  local ns="${NAMESPACE:-}"
  if [[ -z "$ctx" || -z "$ns" ]] || ! command -v "$kbin" >/dev/null 2>&1; then
    echo "Cannot derive LiteLLM master key: CONTEXT/NAMESPACE unset or ${kbin} not on PATH."
    export LITELLM_MASTER_KEY=""
    return 0
  fi

  if [[ -n "${LITELLM_MASTER_KEY_SECRET_NAME:-}" ]]; then
    echo "Attempting to read LiteLLM master key from Secret ${LITELLM_MASTER_KEY_SECRET_NAME} in ${ns}..."
    if _litellm_try_secret "$kbin" "$ctx" "$ns" "$LITELLM_MASTER_KEY_SECRET_NAME"; then
      return 0
    fi
    echo "WARN: Secret ${LITELLM_MASTER_KEY_SECRET_NAME} in ${ns} did not expose a recognized master key field."
    export LITELLM_MASTER_KEY=""
    return 0
  fi

  local infer_pod="${LITELLM_MASTER_KEY_INFER_FROM_POD:-true}"
  local exec_fallback="${LITELLM_MASTER_KEY_EXEC_FALLBACK:-true}"
  if [[ "$infer_pod" == "true" || "$infer_pod" == "True" || "$infer_pod" == "1" ]]; then
    echo "Attempting to infer LiteLLM master key from Pods backing svc/${LITELLM_SERVICE_NAME:-<unset>} in ${ns}..."
    if _litellm_try_workload_env "$kbin" "$ctx" "$ns" "${LITELLM_SERVICE_NAME:-}"; then
      return 0
    fi
    echo "Pod spec inspection did not yield a resolvable master key (missing RBAC on the referenced Secret, or env wired via envFrom.secretRef)."

    if [[ "$exec_fallback" == "true" || "$exec_fallback" == "True" || "$exec_fallback" == "1" ]]; then
      echo "Attempting exec fallback: kubectl exec <pod> -- printenv ..."
      if _litellm_try_workload_exec "$kbin" "$ctx" "$ns" "${LITELLM_SERVICE_NAME:-}"; then
        return 0
      fi
      echo "Exec fallback did not return a non-empty value for any recognized env var."
    fi
  fi

  local pattern="${LITELLM_MASTER_KEY_SECRET_PATTERN:-litellm}"
  echo "Falling back to Secret name-pattern search (pattern: ${pattern}) in ${ns}..."
  local candidates
  candidates=$("$kbin" --context "$ctx" -n "$ns" get secrets -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | grep -iE "$pattern" || true)

  if [[ -z "$candidates" ]]; then
    echo "No Secrets in ${ns} matched pattern '${pattern}'."
  fi

  local sname
  while IFS= read -r sname; do
    [[ -z "$sname" ]] && continue
    if _litellm_try_secret "$kbin" "$ctx" "$ns" "$sname"; then
      return 0
    fi
  done <<<"$candidates"

  echo "No LiteLLM master key supplied and none could be auto-derived from secrets in namespace ${ns} (pattern: ${pattern})."
  export LITELLM_MASTER_KEY=""
  return 0
}

# Wrapper used by Suite Setup: resolves the key and persists it (mode 600) for
# per-task scripts to reuse via the cache fast path. Always returns 0.
resolve_and_cache_master_key() {
  local cache_file="${LITELLM_MASTER_KEY_CACHE_FILE:-./.litellm_master_key}"
  resolve_master_key
  if [[ -n "${LITELLM_MASTER_KEY:-}" ]]; then
    ( umask 077; printf '%s' "$LITELLM_MASTER_KEY" > "$cache_file" )
    echo "Cached LiteLLM master key to ${cache_file}."
  else
    rm -f "$cache_file" 2>/dev/null || true
    echo "No LiteLLM master key resolved; cache file not written."
  fi
  return 0
}
