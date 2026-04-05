#!/usr/bin/env bash
# Shared helpers for PostgresCluster PgBouncer spec validation (sourced by task scripts).

KUBECTL="${KUBERNETES_DISTRIBUTION_BINARY:-kubectl}"

list_postgrescluster_names() {
  local ns="$1"
  "$KUBECTL" get postgresclusters.postgres-operator.crunchydata.com -n "$ns" \
    --context "$CONTEXT" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true
}

get_postgrescluster_json() {
  local ns="$1" name="$2"
  "$KUBECTL" get postgresclusters.postgres-operator.crunchydata.com "$name" -n "$ns" \
    --context "$CONTEXT" -o json 2>/dev/null
}
