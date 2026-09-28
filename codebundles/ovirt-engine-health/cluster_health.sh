#!/bin/bash
# Assess oVirt cluster health by cross-referencing each cluster's hosts. A
# cluster is flagged when it has one or more hosts in a non-up, non-maintenance
# state (i.e. hosts that should be serving but are not).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/ovirt_auth.sh"

clusters_json=$(ovirt_get "/clusters")
hosts_json=$(ovirt_get "/hosts")

echo "${clusters_json}" | jq --argjson hostsdoc "${hosts_json}" '
  ($hostsdoc.host // []) as $allhosts |
  def down_in($cid): [ $allhosts[]
    | select((.cluster.id // "") == $cid)
    | select(((.status // "") | IN("up","maintenance","preparing_for_maintenance")) | not) ];
  {
    clusters: [ .cluster[]? | .id as $cid | {
      name: .name,
      id: $cid,
      total_hosts: ([ $allhosts[] | select((.cluster.id // "") == $cid) ] | length),
      down_hosts: (down_in($cid) | length)
    } ],
    problem_clusters: [ .cluster[]? | .id as $cid
      | (down_in($cid)) as $down
      | select(($down | length) > 0)
      | {
          name: .name,
          id: $cid,
          down_hosts: ($down | length),
          down_host_names: [ $down[] | .name ]
        }
    ]
  }'
