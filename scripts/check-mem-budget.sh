#!/usr/bin/env bash
# Sum every mem_limit in the rendered compose config, profiles included, and fail
# if the total is over 14 GiB or any service has no mem_limit. CT 210 has 16 GiB
# (ADR-026); the other 2 GiB is left for the Docker daemon, sshd and the kernel.
#
#   scripts/check-mem-budget.sh [env-file]
#
# env-file defaults to compose/.env. Use a scratch file outside the repo when the
# real one is absent; only interpolation needs it, no value is printed.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
env_file="${1:-$root/compose/.env}"
budget=$((14 * 1024 * 1024 * 1024))

json="$(docker compose -f "$root/compose/docker-compose.yml" --env-file "$env_file" --profile '*' config --format json)"

printf '%-20s %10s\n' SERVICE MiB
echo "$json" | jq -r '.services | to_entries[] | "\(.key) \(.value.mem_limit // 0)"' |
  sort | while read -r svc bytes; do
    printf '%-20s %10s\n' "$svc" "$((bytes / 1048576))"
  done

total="$(echo "$json" | jq '[.services[].mem_limit // 0 | tonumber] | add')"
nolimit="$(echo "$json" | jq -r '[.services | to_entries[] | select((.value.mem_limit // 0 | tonumber) == 0) | .key] | join(" ")')"

printf '%-20s %10s\n' TOTAL "$((total / 1048576))"
printf '%-20s %10s\n' BUDGET "$((budget / 1048576))"
printf '%-20s %10s\n' SPARE "$(((budget - total) / 1048576))"

status=0
if [ -n "$nolimit" ]; then echo "FAIL: no mem_limit on: $nolimit" >&2; status=1; fi
if [ "$total" -gt "$budget" ]; then echo "FAIL: total is over 14 GiB" >&2; status=1; fi
[ "$status" -eq 0 ] && echo "OK: within 14 GiB, every service capped"
exit "$status"
