#!/usr/bin/env bash
# Read-only snapshot of the state that the first deploy from this repo must not
# change: the two running containers, their volumes, the Qdrant collections and the
# SeaweedFS buckets. Run it on CT 210 before the deploy and again after, then diff.
#
#   ssh root@192.168.1.60 'bash -s' < scripts/snapshot-state.sh > before.txt
#   ssh root@192.168.1.60 'bash -s' < scripts/snapshot-state.sh > after.txt
#   diff before.txt after.txt
#
# Credentials are read from an .env file on the host and never printed. Before the
# deploy that is /opt/ai-platform-stack/.env. Override with ENV_FILE=/path/to/.env.
#
# Container ids are expected to change on the first deploy, because mem_limit is
# added and Compose recreates the containers. The volumes, the collections and the
# buckets must not. Those lines carry the marker "STABLE"; ids carry "ID".
set -uo pipefail

env_file="${ENV_FILE:-/opt/ai-platform-stack/.env}"
[ -r "$env_file" ] || { echo "cannot read $env_file" >&2; exit 1; }

get() { grep -E "^$1=" "$env_file" | tail -n 1 | cut -d= -f2-; }
bind="$(get BIND_ADDRESS)"
qport="$(get QDRANT_REST_PORT)"; qport="${qport:-6333}"
sport="$(get SEAWEEDFS_S3_PORT)"; sport="${sport:-8333}"
qkey="$(get QDRANT_API_KEY)"
ak="$(get SEAWEEDFS_S3_ACCESS_KEY)"
sk="$(get SEAWEEDFS_S3_SECRET_KEY)"
empty=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855

for c in ai-platform-qdrant ai-platform-seaweedfs; do
  echo "ID     container $c $(docker inspect -f '{{.Id}} started={{.State.StartedAt}}' "$c" 2>&1)"
  docker inspect -f '{{range .Mounts}}STABLE mount {{.Name}} -> {{.Destination}}{{"\n"}}{{end}}' "$c" 2>&1 | sed '/^$/d;s/^/  /' | sed "s/^  STABLE/STABLE $c/"
done
docker volume ls --format 'STABLE volume {{.Name}}' | sort
docker network ls --format 'STABLE network {{.Name}}' | grep ai-platform | sort

echo "STABLE qdrant collections:"
curl -fsS -H "api-key: $qkey" "http://$bind:$qport/collections" 2>&1 | grep -o '"name":"[^"]*"' | sort | sed 's/^/  /'
echo "STABLE qdrant collections raw:"
curl -fsS -H "api-key: $qkey" "http://$bind:$qport/collections" 2>&1 | sed 's/^/  /'; echo

echo "STABLE seaweedfs buckets:"
curl -fsS --aws-sigv4 "aws:amz:us-east-1:s3" --user "$ak:$sk" -H "x-amz-content-sha256: $empty" \
  "http://$bind:$sport/" 2>&1 | grep -o '<Name>[^<]*</Name>' | sed 's/<[^>]*>//g' | sort | sed 's/^/  /'
