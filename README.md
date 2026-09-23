# ai-platform-layer

The shared AI platform layer for CT 210 (ai-platform-01): object storage, vector
storage, tracing and an LLM gateway, run as one Docker Compose project. It is
infrastructure for several projects to share. It contains no application code.

`ai-platform-stack` is no longer the platform source for CT 210. SeaweedFS and
Qdrant moved here unchanged (ADR-025), and that repository is not modified.

There is no Kubernetes today and there are no Kubernetes files in this repo.

## Services

Compose project name: `ai-platform-stack` (kept from the legacy repo on purpose,
ADR-025). Default network: `ai-platform-stack_default`.

| Service | Image | Published (LAN only) | mem_limit |
|---|---|---|---|
| `seaweedfs` | `chrislusf/seaweedfs:4.41` | `${BIND_ADDRESS}:8333` S3 API | 224m |
| `qdrant` | `qdrant/qdrant:v1.19.0` | `${BIND_ADDRESS}:6333` REST | 128m |

Everything else stays on the compose network. Later stages add Langfuse and the
LiteLLM gateway to this table.

## How it is deployed

Terraform in a private homelab repo copies the files below to CT 210 through a
`null_resource` with hash triggers, then runs `docker compose up -d`. Deployment is
done by the operator after a push. This repo contains no Terraform and no way to
deploy itself. Ingress is the Traefik LXC (151); no proxy or route is defined here.

### Files that must be deployed

```
compose/docker-compose.yml
compose/seaweedfs/s3.identities.example.json   reference only, not read by any container
```

`compose/.env` is not in the repo. It must exist on the host, mode 600, and it is
where every secret lives.

### First deploy from this repo

The running containers hold data, so the first deploy adopts them:

1. Seed `compose/.env` from `/opt/ai-platform-stack/.env` on the host. The
   SeaweedFS and Qdrant credentials must be carried over unchanged.
2. Run `scripts/gen-secrets.sh`. It never overwrites a set value.
3. Never run `docker compose down -v` in `/opt/ai-platform-stack`. Its named
   volumes are the same volumes this project uses.

The containers are recreated once, because `mem_limit` was added. The volumes are
reused.

## Memory

CT 210 has 8 GiB and no swap (ADR-024). Every service has a `mem_limit`, and the
sum stays at or under 7 GiB. `scripts/check-mem-budget.sh` prints the table and
fails if the sum is over budget or any service is uncapped.

## Repo layout

```
compose/     docker-compose.yml, per-service config, .env.example
docs/adr/    decisions
scripts/     gen-secrets.sh, check-mem-budget.sh
CLAUDE.md    rules for sessions working in this repo
```
