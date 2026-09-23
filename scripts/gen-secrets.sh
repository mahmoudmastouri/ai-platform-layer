#!/usr/bin/env bash
# Create compose/.env if needed and fill generated secrets without overwriting.
#
#   scripts/gen-secrets.sh            fill what can be generated, warn about the rest
#   scripts/gen-secrets.sh --strict   same, but exit 1 if any variable is still empty
#
# Rules:
#   - An existing non-empty value is never changed.
#   - Every variable listed in compose/.env.example that is absent from .env is
#     appended, empty, so the file always shows the full set.
#   - SeaweedFS and Qdrant credentials are NOT generated here. They belong to data
#     that already exists and must be carried over from the running deployment.
#   - Provider keys (ANTHROPIC_API_KEY and friends) come from the operator.
#   - Generated values are hex or hex with a fixed prefix, so they are safe inside
#     URLs and unquoted .env lines.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
env_file="$root/compose/.env"
example="$root/compose/.env.example"
strict=0
[ "${1:-}" = "--strict" ] && strict=1

# name:generator. Generators: hex:<bytes> or prefixed:<prefix>:<bytes>
generated=(
  SALT:hex:32
  ENCRYPTION_KEY:hex:32
  NEXTAUTH_SECRET:hex:32
  POSTGRES_PASSWORD:hex:24
  CLICKHOUSE_PASSWORD:hex:24
  REDIS_AUTH:hex:24
  LANGFUSE_INIT_USER_PASSWORD:hex:16
  LANGFUSE_INIT_PROJECT_PUBLIC_KEY:prefixed:pk-lf-:16
  LANGFUSE_INIT_PROJECT_SECRET_KEY:prefixed:sk-lf-:16
)

hex() { head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'; }

gen_value() {
  case "$1" in
    hex:*) hex "${1#hex:}" ;;
    prefixed:*) local rest="${1#prefixed:}"; printf '%s%s' "${rest%%:*}" "$(hex "${rest##*:}")" ;;
    *) echo "unknown generator: $1" >&2; return 1 ;;
  esac
}

get_value() { grep -E "^$1=" "$env_file" | tail -n 1 | cut -d= -f2- || true; }

set_value() {
  local name="$1" value="$2" tmp
  tmp="$(mktemp "$env_file.XXXXXX")"
  if grep -qE "^$name=" "$env_file"; then
    awk -v n="$name" -v v="$value" 'BEGIN{FS=OFS="="} $1==n {print n "=" v; next} {print}' "$env_file" > "$tmp"
  else
    cat "$env_file" > "$tmp"
    printf '%s=%s\n' "$name" "$value" >> "$tmp"
  fi
  chmod 600 "$tmp"
  mv "$tmp" "$env_file"
}

if [ ! -f "$env_file" ]; then
  ( umask 077; : > "$env_file" )
  echo "created $env_file"
fi
chmod 600 "$env_file"

# 1. Make the variable set complete.
while IFS= read -r line; do
  case "$line" in
    [A-Za-z_]*=*) name="${line%%=*}"
      grep -qE "^$name=" "$env_file" || printf '%s=\n' "$name" >> "$env_file" ;;
  esac
done < "$example"

# 2. Generate what is empty.
for entry in "${generated[@]}"; do
  name="${entry%%:*}"; gen="${entry#*:}"
  if [ -z "$(get_value "$name")" ]; then
    set_value "$name" "$(gen_value "$gen")"
    echo "generated $name"
  fi
done

# 3. Report what is still empty. Names only, never values.
missing=()
while IFS= read -r line; do
  case "$line" in
    [A-Za-z_]*=*) name="${line%%=*}"
      [ -n "$(get_value "$name")" ] || missing+=("$name") ;;
  esac
done < "$example"

if [ "${#missing[@]}" -gt 0 ]; then
  echo "still empty in compose/.env (operator must supply, or compose applies its default):" >&2
  printf '  %s\n' "${missing[@]}" >&2
  [ "$strict" -eq 1 ] && exit 1
fi
exit 0
