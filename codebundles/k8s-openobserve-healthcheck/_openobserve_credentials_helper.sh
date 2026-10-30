#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Shared helper to resolve the OpenObserve admin credentials
# (OPENOBSERVE_USERNAME / OPENOBSERVE_PASSWORD) used for HTTP Basic auth.
#
# Resolution order (first hit wins):
#   0. Cached credentials in OPENOBSERVE_CREDENTIALS_CACHE_FILE
#      (default: ./.openobserve_credentials). This is what Suite Setup writes
#      via resolve-openobserve-credentials.sh so the downstream per-task
#      scripts do not re-run kubectl.
#   1. openobserve_credentials (RW secret env var) - JSON like
#      {"username": "root@example.com", "password": "..."} or {"email": ..., "password": ...}.
#   2. OPENOBSERVE_CREDENTIAL_SECRET_NAME set -> read that Secret from
#      $NAMESPACE, preferring OPENOBSERVE_CREDENTIAL_USER_KEY /
#      OPENOBSERVE_CREDENTIAL_PASSWORD_KEY, else probe common candidate keys.
#   3. Infer from the OpenObserve workload's Pod env vars:
#      username: ROOT_USER_EMAIL, ZO_ROOT_USER_EMAIL, ROOT_USER_NAME
#      password: ROOT_USER_PASSWORD, ZO_ROOT_USER_PASSWORD
#      Following valueFrom.secretKeyRef where referenced.
#   4. Exec fallback: `kubectl exec <pod> -- printenv <NAME>`, gated by
#      OPENOBSERVE_ALLOW_EXEC=true (default false).
#
# Required for steps 2-4: CONTEXT, NAMESPACE, and kubectl on PATH. Step 3/4
# also need a way to find the backing Pod (OPENOBSERVE_SERVICE_NAME or
# OBJECT_NAME).
#
# The credential values are never printed; only the derivation source is.
# On success the helper exports OPENOBSERVE_USERNAME and OPENOBSERVE_PASSWORD.
# -----------------------------------------------------------------------------

OPENOBSERVE_CREDENTIALS_CACHE_FILE="${OPENOBSERVE_CREDENTIALS_CACHE_FILE:-./.openobserve_credentials}"

# Common Secret data keys probed when a specific key is not provided.
_OPENOBSERVE_USER_KEYS=(ROOT_USER_EMAIL ZO_ROOT_USER_EMAIL ROOT_USER_NAME username user email emailId)
_OPENOBSERVE_PASS_KEYS=(ROOT_USER_PASSWORD ZO_ROOT_USER_PASSWORD password pass)

# Env-var names we recognize on the OpenObserve container when scanning pod spec.
_OPENOBSERVE_USER_ENV_NAMES=(ROOT_USER_EMAIL ZO_ROOT_USER_EMAIL ROOT_USER_NAME)
_OPENOBSERVE_PASS_ENV_NAMES=(ROOT_USER_PASSWORD ZO_ROOT_USER_PASSWORD)

_openobserve_sanitize() {
  local raw="$1"
  raw="${raw#"${raw%%[![:space:]]*}"}"
  raw="${raw%"${raw##*[![:space:]]}"}"
  if [[ -z "$raw" || "$raw" == '${EMPTY}' || "$raw" == 'None' ]]; then
    return 1
  fi
  printf '%s' "$raw"
}

_openobserve_read_secret_key() {
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

_openobserve_try_secret() {
  local kbin="$1" ctx="$2" ns="$3" sname="$4"
  local ukeys=() pkeys=()
  if [[ -n "${OPENOBSERVE_CREDENTIAL_USER_KEY:-}" ]]; then
    ukeys=("$OPENOBSERVE_CREDENTIAL_USER_KEY")
  else
    ukeys=("${_OPENOBSERVE_USER_KEYS[@]}")
  fi
  if [[ -n "${OPENOBSERVE_CREDENTIAL_PASSWORD_KEY:-}" ]]; then
    pkeys=("$OPENOBSERVE_CREDENTIAL_PASSWORD_KEY")
  else
    pkeys=("${_OPENOBSERVE_PASS_KEYS[@]}")
  fi
  local ukey pkey uval pval
  for ukey in "${ukeys[@]}"; do
    uval=$(_openobserve_read_secret_key "$kbin" "$ctx" "$ns" "$sname" "$ukey" || true)
    if [[ -n "$uval" ]]; then
      for pkey in "${pkeys[@]}"; do
        pval=$(_openobserve_read_secret_key "$kbin" "$ctx" "$ns" "$sname" "$pkey" || true)
        if [[ -n "$pval" ]]; then
          export OPENOBSERVE_USERNAME="$uval"
          export OPENOBSERVE_PASSWORD="$pval"
          echo "Derived OpenObserve credentials from secret ${sname} keys ${ukey}/${pkey} in namespace ${ns}."
          return 0
        fi
      done
      echo "WARN: Secret ${sname} has username key ${ukey} but no matching password key could be read."
      return 1
    fi
  done
  echo "WARN: Secret ${sname} did not expose a recognized username/password key pair."
  return 1
}

# Find Pods backing a workload (OBJECT_NAME) or Service (OPENOBSERVE_SERVICE_NAME).
_openobserve_find_pods() {
  local kbin="$1" ctx="$2" ns="$3"
  local selector=""
  local name_filter=""

  if [[ -n "${OPENOBSERVE_SERVICE_NAME:-}" ]]; then
    selector=$("$kbin" --context "$ctx" -n "$ns" get svc "$OPENOBSERVE_SERVICE_NAME" -o json 2>/dev/null \
      | jq -r '.spec.selector // {} | to_entries | map("\(.key)=\(.value)") | join(",")' 2>/dev/null || true)
    if [[ -z "$selector" ]]; then
      name_filter="$OPENOBSERVE_SERVICE_NAME"
    fi
  elif [[ -n "${OBJECT_NAME:-}" ]]; then
    for kind in statefulset deployment; do
      selector=$("$kbin" --context "$ctx" -n "$ns" get "$kind" "$OBJECT_NAME" -o json 2>/dev/null \
        | jq -r '.spec.selector.matchLabels // {} | to_entries | map("\(.key)=\(.value)") | join(",")' 2>/dev/null || true)
      if [[ -n "$selector" ]]; then
        break
      fi
    done
    if [[ -z "$selector" ]]; then
      name_filter="^${OBJECT_NAME}"
    fi
  else
    return 1
  fi

  if [[ -n "$selector" && "$selector" != "{}" ]]; then
    "$kbin" --context "$ctx" -n "$ns" get pods -l "$selector" \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true
  elif [[ -n "$name_filter" ]]; then
    "$kbin" --context "$ctx" -n "$ns" get pods -o json 2>/dev/null \
      | jq -r --arg re "$name_filter" '.items[].metadata.name | select(test($re))' 2>/dev/null || true
  fi
}

# Scans a pod's containers[].env[] for a matching env name and resolves the
# value via literal `.value` or `valueFrom.secretKeyRef`.
_openobserve_try_pod_env() {
  local kbin="$1" ctx="$2" ns="$3" pod="$4"
  local want_name="$5" out_var="$6"
  if ! command -v jq >/dev/null 2>&1; then
    return 1
  fi
  local pod_json
  pod_json=$("$kbin" --context "$ctx" -n "$ns" get pod "$pod" -o json 2>/dev/null || echo "")
  [[ -z "$pod_json" ]] && return 1
  local entry
  entry=$(echo "$pod_json" | jq -c --arg name "$want_name" '
    [ .spec.containers[]?.env[]? | select(.name == $name) ][0] // empty
  ')
  if [[ -z "$entry" || "$entry" == "null" ]]; then
    return 1
  fi
  local literal sref_name sref_key val
  literal=$(echo "$entry" | jq -r '.value // ""')
  sref_name=$(echo "$entry" | jq -r '.valueFrom.secretKeyRef.name // ""')
  sref_key=$(echo "$entry" | jq -r '.valueFrom.secretKeyRef.key // ""')
  if [[ -n "$literal" ]]; then
    printf -v "$out_var" '%s' "$literal"
    echo "Derived OpenObserve ${want_name} from pod ${pod} env (literal value)."
    return 0
  fi
  if [[ -n "$sref_name" && -n "$sref_key" ]]; then
    val=$(_openobserve_read_secret_key "$kbin" "$ctx" "$ns" "$sref_name" "$sref_key" || true)
    if [[ -n "$val" ]]; then
      printf -v "$out_var" '%s' "$val"
      echo "Derived OpenObserve ${want_name} from pod ${pod} env ${want_name} -> secret ${sref_name}[${sref_key}]."
      return 0
    fi
    echo "WARN: Pod ${pod} env ${want_name} references secret ${sref_name}[${sref_key}] but the Secret could not be read."
  fi
  return 1
}

_openobserve_try_pod_exec() {
  local kbin="$1" ctx="$2" ns="$3" pod="$4"
  local want_name="$5" out_var="$6"
  local val
  val=$("$kbin" --context "$ctx" -n "$ns" exec "$pod" -- printenv "$want_name" 2>/dev/null \
    | tr -d '\r\n' || true)
  if [[ -z "$val" ]]; then
    val=$("$kbin" --context "$ctx" -n "$ns" exec "$pod" -- sh -c "printf %s \"\${${want_name}:-}\"" 2>/dev/null \
      | tr -d '\r\n' || true)
  fi
  if [[ -n "$val" ]]; then
    printf -v "$out_var" '%s' "$val"
    echo "Derived OpenObserve ${want_name} by exec-ing pod ${pod}."
    return 0
  fi
  return 1
}

# Resolves a single credential (username or password) across pod-credential
# strategies. Invokes the callback with (kbin ctx ns pod env_name out_var).
_openobserve_resolve_from_pods() {
  local type="$1" # "user" or "pass"
  local kbin="${KUBERNETES_DISTRIBUTION_BINARY:-kubectl}"
  local ctx="${CONTEXT:-}"
  local ns="${NAMESPACE:-}"
  local out_var="$2"
  local env_names
  if [[ "$type" == "user" ]]; then
    env_names=("${_OPENOBSERVE_USER_ENV_NAMES[@]}")
  else
    env_names=("${_OPENOBSERVE_PASS_ENV_NAMES[@]}")
  fi
  local pods p env_name val
  pods=$(_openobserve_find_pods "$kbin" "$ctx" "$ns" || true)
  [[ -z "$pods" ]] && return 1
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    for env_name in "${env_names[@]}"; do
      if _openobserve_try_pod_env "$kbin" "$ctx" "$ns" "$p" "$env_name" "$out_var"; then
        return 0
      fi
    done
  done <<<"$pods"

  if [[ "${OPENOBSERVE_ALLOW_EXEC:-false}" == "true" || "${OPENOBSERVE_ALLOW_EXEC:-false}" == "True" ]]; then
    while IFS= read -r p; do
      [[ -z "$p" ]] && continue
      for env_name in "${env_names[@]}"; do
        if _openobserve_try_pod_exec "$kbin" "$ctx" "$ns" "$p" "$env_name" "$out_var"; then
          local tmp=""
          printf -v tmp '%s' "${!out_var}"
          echo "...resolved ${type} credential by exec fallback of pod ${p} env ${env_name}."
          return 0
        fi
      done
    done <<<"$pods"
  fi
  return 1
}

resolve_openobserve_credentials() {
  # Step 0: cache fast path.
  if [[ -s "$OPENOBSERVE_CREDENTIALS_CACHE_FILE" ]]; then
    local cuser cpass
    cuser=$(sed -n '1p' "$OPENOBSERVE_CREDENTIALS_CACHE_FILE")
    cpass=$(sed -n '2p' "$OPENOBSERVE_CREDENTIALS_CACHE_FILE")
    if [[ -n "$cuser" && -n "$cpass" ]]; then
      export OPENOBSERVE_USERNAME="$cuser"
      export OPENOBSERVE_PASSWORD="$cpass"
      echo "Using OpenObserve credentials from cache file ${OPENOBSERVE_CREDENTIALS_CACHE_FILE}."
      return 0
    fi
  fi

  # Step 1: RW.CLI secret injection (env var `openobserve_credentials`).
  local sanitized
  if [[ -n "${openobserve_credentials:-}" ]]; then
    local creds_json="${openobserve_credentials}"
    local u p
    u=$(echo "$creds_json" | jq -r '.username // .email // .emailId // empty' 2>/dev/null || true)
    p=$(echo "$creds_json" | jq -r '.password // empty' 2>/dev/null || true)
    if [[ -n "$u" && -n "$p" ]]; then
      export OPENOBSERVE_USERNAME="$u"
      export OPENOBSERVE_PASSWORD="$p"
      echo "Using OpenObserve credentials from imported openobserve_credentials secret."
      return 0
    fi
    echo "WARN: openobserve_credentials secret provided but not in expected JSON {username|email, password} format."
  fi

  # If one of the values is already provided explicitly via env (e.g. from the
  # taskset config), honor it. This is rarely the case for this bundle.
  if [[ -n "${OPENOBSERVE_USERNAME:-}" && -n "${OPENOBSERVE_PASSWORD:-}" ]]; then
    echo "Using OpenObserve credentials from environment variables."
    return 0
  fi

  local kbin="${KUBERNETES_DISTRIBUTION_BINARY:-kubectl}"
  local ctx="${CONTEXT:-}"
  local ns="${NAMESPACE:-}"
  if [[ -z "$ctx" || -z "$ns" ]] || ! command -v "$kbin" >/dev/null 2>&1; then
    echo "Cannot derive OpenObserve credentials: CONTEXT/NAMESPACE unset or ${kbin} not on PATH."
    export OPENOBSERVE_USERNAME=""
    export OPENOBSERVE_PASSWORD=""
    return 0
  fi

  # Step 2: explicit Secret name.
  if [[ -n "${OPENOBSERVE_CREDENTIAL_SECRET_NAME:-}" ]]; then
    echo "Attempting to read OpenObserve credentials from Secret ${OPENOBSERVE_CREDENTIAL_SECRET_NAME} in ${ns}..."
    if _openobserve_try_secret "$kbin" "$ctx" "$ns" "$OPENOBSERVE_CREDENTIAL_SECRET_NAME"; then
      return 0
    fi
    echo "WARN: Secret ${OPENOBSERVE_CREDENTIAL_SECRET_NAME} in ${ns} did not expose a recognized username/password pair."
  fi

  # Step 3: Pod env inference.
  local step3_user="" step3_pass=""
  if _openobserve_resolve_from_pods user step3_user; then
    if _openobserve_resolve_from_pods pass step3_pass; then
      export OPENOBSERVE_USERNAME="$step3_user"
      export OPENOBSERVE_PASSWORD="$step3_pass"
      echo "Resolved OpenObserve credentials from the workload Pod environment."
      return 0
    fi
  fi
  echo "Pod spec/env inference did not yield a resolvable username/password pair."

  export OPENOBSERVE_USERNAME=""
  export OPENOBSERVE_PASSWORD=""
  echo "No OpenObserve credentials supplied and none could be auto-derived. API calls will likely return HTTP 401."
  return 0
}

# Wrapper used by Suite Setup: resolves the credentials and persists them
# (mode 600) for per-task scripts to reuse via the cache fast path.
resolve_and_cache_openobserve_credentials() {
  resolve_openobserve_credentials
  if [[ -n "${OPENOBSERVE_USERNAME:-}" && -n "${OPENOBSERVE_PASSWORD:-}" ]]; then
    ( umask 077; printf '%s\n%s\n' "$OPENOBSERVE_USERNAME" "$OPENOBSERVE_PASSWORD" > "$OPENOBSERVE_CREDENTIALS_CACHE_FILE" )
    echo "Cached OpenObserve credentials to ${OPENOBSERVE_CREDENTIALS_CACHE_FILE}."
  else
    rm -f "$OPENOBSERVE_CREDENTIALS_CACHE_FILE" 2>/dev/null || true
    echo "No OpenObserve credentials resolved; cache file not written."
  fi
  return 0
}