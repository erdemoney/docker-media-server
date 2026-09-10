#!/usr/bin/env bash
set -euo pipefail

NETWORKS=(internal external)

for net in "${NETWORKS[@]}"; do
  if docker network inspect "$net" >/dev/null 2>&1; then
    echo "$net: exists"
  else
    echo "$net: creating"
    docker network create "$net"
  fi
done