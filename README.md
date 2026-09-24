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
| `langfuse-web` | `ghcr.io/langfuse/langfuse:4.41.0` | `${BIND_ADDRESS}:3000` UI and API | 2g |
| `langfuse-worker` | `ghcr.io/langfuse/langfuse-worker:4.41.0` | none | 1g |
| `clickhouse` | `clickhouse/clickhouse-server:26.4.5.143` | none | 2560m |
| `postgres` | `postgres:17.11-alpine3.24` | none | 512m |
| `valkey` | `valkey/valkey:9.0.6-alpine3.24` | none | 256m |
| `seaweedfs-init` | `chrislusf/seaweedfs:4.41` (one-shot) | none | 32m |
| `litellm` | `ghcr.io/berriai/litellm:v1.102.1@sha256:87f34979...ce20d02` | `${BIND_ADDRESS}:4000` gateway | 768m |
| `fault-stub` | `python:3.13.15-slim` (profile `faults` only) | none | 64m |

Everything not published stays on the compose network. There is no reverse proxy here:
Traefik (LXC 151) routes to the published ports.

### LiteLLM gateway

Config-file mode, no database, no logging callbacks, admin UI disabled, telemetry off,
master key auth. Client-facing model groups are `generator`, `judge`, `embedder`,
`generator-fault-timeout` and `generator-fault-5xx`; `generator-fallback-openai`
is the fallback target and also appears in `/v1/models`. The chain has two providers today
(Anthropic, then OpenAI); OpenRouter is deferred to box L11 (Jev step). Fallback order,
timeouts, prices and the reasons are in `compose/litellm/config.yaml` and ADR-018.
Fallbacks are visible only in response headers (`x-litellm-model-group`,
`x-litellm-attempted-fallbacks`). The image digest was verified with cosign; do not
change the tag without verifying the new digest.

Fault tests: `docker compose --profile faults up -d fault-stub`, then call
`generator-fault-5xx` and `generator-fault-timeout`. Stop the stub afterwards with
`docker compose --profile faults stop fault-stub`.

### Langfuse

Langfuse v4, single node, ClickHouse cluster mode off, telemetry off, signups off.
The organisation, project, API keys and first user are created from `compose/.env`
on first boot. Event blobs are written to the `langfuse-events` bucket in SeaweedFS
(`http://seaweedfs:8333`, path-style), created by `seaweedfs-init`. Media upload and
batch export are disabled. `langfuse-web` runs the database migrations, so the worker
waits for it. ClickHouse is capped by `max_server_memory_usage` (2147483648 bytes) in
`compose/clickhouse/config.d/langfuse.xml`. Valkey is capped at `maxmemory 200mb` with
`noeviction` in `compose/valkey/valkey.conf`.

Postgres, ClickHouse and Valkey data live in named volumes `postgres_data`,
`clickhouse_data` and `valkey_data`. They are the demo tier and are disposable: a
destroyed CT 210 loses traces (ADR-022).

## How it is deployed

Terraform in a private homelab repo copies the files below to CT 210 through a
`null_resource` with hash triggers, then runs `docker compose up -d`. Deployment is
done by the operator after a push. This repo contains no Terraform and no way to
deploy itself. Ingress is the Traefik LXC (151); no proxy or route is defined here.

### Files that must be deployed

```
compose/docker-compose.yml
compose/.env.example                           read by scripts/gen-secrets.sh
compose/clickhouse/config.d/langfuse.xml       bind-mounted into clickhouse
compose/valkey/valkey.conf                     bind-mounted into valkey
compose/litellm/config.yaml                    bind-mounted into litellm
compose/seaweedfs/s3.identities.example.json   reference only, not read by any container
scripts/gen-secrets.sh                         run on the host to fill compose/.env
scripts/snapshot-state.sh                      optional, pre and post deploy state diff
scripts/acceptance.sh                          optional, post-deploy checks
```

The three bind-mounted config files must stay world-readable (mode 644). The
containers run as their own users and a 600 file is unreadable to them.

`compose/.env` is not in the repo. It must exist on the host, mode 600, and it is
where every secret lives.

### First deploy from this repo

The running containers hold data, so the first deploy adopts them:

1. Seed `compose/.env` from `/opt/ai-platform-stack/.env` on the host. The
   SeaweedFS and Qdrant credentials must be carried over unchanged.
2. Run `scripts/gen-secrets.sh`. It never overwrites a set value. It generates the
   Langfuse secrets and project keys. It does not generate the SeaweedFS or Qdrant
   credentials, which belong to existing data.
3. Never run `docker compose down -v` in `/opt/ai-platform-stack`. Its named
   volumes are the same volumes this project uses.

The containers are recreated once, because `mem_limit` was added. The volumes are
reused.

## Acceptance

Before the deploy: `docker compose config` validates, `scripts/check-mem-budget.sh`
passes, `git ls-files` shows no `.env` and no secrets, and the running SeaweedFS and
Qdrant match the rendered config. Take a baseline with
`ssh root@192.168.1.60 'bash -s' < scripts/snapshot-state.sh > before.txt`.

After the deploy: `ssh root@192.168.1.60 'bash -s -- full' < scripts/acceptance.sh`
(`full` needs the stub running), then repeat `snapshot-state.sh` and diff. Run the
`stats` phase again after five minutes idle for the memory record.

## Memory

CT 210 has 8 GiB and no swap (ADR-024). Every service has a `mem_limit`, and the
sum stays at or under 8 GiB. That figure is the CT's own cgroup limit, and the
cgroup is what protects the host; per-service limits only allocate within it and
decide which container is killed first. `scripts/check-mem-budget.sh` prints the
table and fails if the sum is over budget or any service is uncapped.

| Service | mem_limit (MiB) | Basis |
|---|---|---|
| clickhouse | 2560 | server cap 2147483648 B (2 GiB) inside it; lowered from 3072 to pay for langfuse-web |
| langfuse-web | 2048 | `NODE_OPTIONS=--max-old-space-size=1536`; crash-looped on heap at 1024 |
| langfuse-worker | 1024 | `NODE_OPTIONS=--max-old-space-size=768` |
| litellm | 768 | estimate, at most 1g allowed |
| valkey | 256 | given; `maxmemory 200mb` inside it |
| postgres | 512 | given |
| seaweedfs | 224 | measured 78 MiB idle |
| qdrant | 128 | measured 40 MiB idle |
| fault-stub | 64 | given, profile only |
| seaweedfs-init | 32 | one-shot |
| **Total** | **7616** | budget 8192, spare 576 |

The measured rows are idle numbers from before Langfuse and the gateway existed. The
post-deploy `stats` phase replaces every estimate with a measurement.

## Repo layout

```
compose/     docker-compose.yml, per-service config, .env.example
docs/adr/    decisions
scripts/     gen-secrets.sh, check-mem-budget.sh, snapshot-state.sh, acceptance.sh
CLAUDE.md    rules for sessions working in this repo
```
