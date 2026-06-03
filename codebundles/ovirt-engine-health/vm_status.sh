#!/bin/bash
# List oVirt virtual machines and flag those in a problematic runtime state.
# 'down' VMs are intentionally NOT flagged (many VMs are deliberately powered
# off); 'paused', 'unknown' and 'not_responding' indicate real problems
# (commonly storage I/O errors or a lost host connection).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/ovirt_auth.sh"

vms_json=$(ovirt_get "/vms")

echo "${vms_json}" | jq '
  def problem: IN("paused","unknown","not_responding");
  {
    total: ([.vm[]?] | length),
    problem_vms: [ .vm[]? | select((.status // "") | problem) | {
      name: .name,
      id: .id,
      status: .status,
      cluster_id: (.cluster.id // ""),
      host_id: (.host.id // "")
    } ]
  }'
