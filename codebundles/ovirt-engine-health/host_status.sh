#!/bin/bash
# List oVirt hypervisor hosts and flag any that are not in a healthy state.
# Hosts in 'maintenance'/'preparing_for_maintenance' are reported separately
# and are NOT treated as unhealthy (they are operator-intended states).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/ovirt_auth.sh"

hosts_json=$(ovirt_get "/hosts")

echo "${hosts_json}" | jq '
  def unhealthy: IN("non_operational","non_responsive","error","install_failed","connecting","down","reboot");
  {
    total: ([.host[]?] | length),
    hosts: [ .host[]? | {
      name: .name,
      id: .id,
      status: (.status // "unknown"),
      cluster_id: (.cluster.id // ""),
      address: (.address // "")
    } ],
    unhealthy_hosts: [ .host[]? | select((.status // "") | unhealthy) | {
      name: .name,
      id: .id,
      status: .status,
      address: (.address // "")
    } ],
    maintenance_hosts: [ .host[]? | select((.status // "") | IN("maintenance","preparing_for_maintenance")) | {
      name: .name,
      status: .status
    } ]
  }'
