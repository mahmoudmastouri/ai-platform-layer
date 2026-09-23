# ADR-025: Platform layer in its own repo

**Date:** 2026-09-24
**Status:** Accepted
**Tags:** #infra #ai-platform

## Context
CT 210 runs SeaweedFS 4.41 and Qdrant v1.19.0 from `ai-platform-stack`, the stack repo ADR-012 created. It now has to host a second tier as well: Langfuse with its Postgres, ClickHouse and Valkey (ADR-022), and a LiteLLM gateway (ADR-018), all shared by several projects. The running containers carry the compose project label `ai-platform-stack` and hold 124 MB of SeaweedFS data in named volumes named after that project. Terraform in a private homelab repo deploys whatever repo it is pointed at, through a `null_resource` with hash triggers, and the deploy must adopt the running containers and volumes instead of recreating them empty.

## Options considered
### Option A: Keep extending ai-platform-stack
No new repo, no move, and the running deployment already comes from it.

### Option B: A new repo, ai-platform-layer, with the compose project name pinned to the legacy value
Move both existing service definitions unchanged, add the new tier, and set `name: ai-platform-stack` at the top of the compose file so volume and network names render as they do today.

### Option C: Put the compose files in the private Terraform repo
One repo for host and containers, as the bootstrap convention for other guests does.

### Option D: Write Kubernetes manifests now
Skip compose growth and target a cluster.

## Decision
Chose Option B. The repo is `ai-platform-layer`, the compose file is `compose/docker-compose.yml`, and its top-level `name:` stays `ai-platform-stack` permanently. `ai-platform-stack` is no longer the platform source for CT 210 and is not modified.

## Reasoning
The compose project name is the prefix of every named volume and of the default network. Docker Compose adopts an existing container, volume or network only when the project name and the logical name match. Verified read-only on the host on 2026-09-23: both containers carry `com.docker.compose.project=ai-platform-stack`, the volumes are `ai-platform-stack_qdrant_data`, `ai-platform-stack_seaweedfs_data` and `ai-platform-stack_seaweedfs_config`, and the network is `ai-platform-stack_default`. A new project name would render new names, and the next `docker compose up` would start SeaweedFS and Qdrant against empty volumes while the data sat unreferenced under the old names. Pinning the name is the only change that keeps the move to one deploy with no data migration.

A separate repo also matches what ADR-012 already decided for the stack: the containers change on a different cadence than the host, so they do not live in the Terraform payload. This layer gains a Postgres, a ClickHouse and a gateway in one week, which is the cadence ADR-012 describes.

## Rejected and why
**Option A, keep extending ai-platform-stack.** Its history is coupled to BCT. Its `CLAUDE.md` also states rules that this work must reverse: Postgres and Langfuse are deliberately absent and are not to be restored, Langfuse is cloud-hosted per ADR-009, and no service is added without an ADR naming its consumer. Extending it means overriding those rules inside a repo whose history readers will take at face value. A layer that hosts Langfuse and a gateway for several projects is a different unit from a storage stack for one.

**Option C, compose in the private Terraform repo.** ADR-012 rejected this for the stack on change cadence and because the infra repo holds host IPs and VMIDs and cannot be published. The second reason is the disqualifier here as well: the compose files, the ADRs and the fault-injection setup cannot be shown to anyone if they live in a repo that contains the rest of the homelab. It also makes the layer's history part of the infrastructure history.

**Option D, Kubernetes manifests now.** There is no cluster. Manifests written against one that does not exist cannot be applied, tested or measured, and would sit in the repo as unverified claims. This is deferred, not refused.

## Consequences
- The compose name is now a legacy value that describes a repo that is no longer the source. It is pinned on purpose and must not be tidied. `CLAUDE.md` states this as a rule.
- Kubernetes is deferred. No Kubernetes files exist here until a cluster does.
- `/opt/ai-platform-stack` on the host still holds a compose file for the same project name. It must not be started again after the first deploy from this repo, and `docker compose down -v` must never be run there, because that would delete the adopted volumes. Removing that directory is a follow-up for after acceptance.
- Both existing services move with the same images, container names, ports, environment variable names, healthchecks and volume definitions. The only change is an added `mem_limit`, which recreates the two containers once. The volumes are reused.
- The deployed file set is explicit and lives in the README, because Terraform hashes and copies files by name and a file missing from that list is missing on the host.
- ADR numbers in this repo are allocated in the homelab ADR directory. ADR-025 and ADR-018 were not present there when this was written and should be copied to it.

## Revisit trigger
Reopen when a Kubernetes cluster exists and this layer is a candidate to run on it, or when SeaweedFS and Qdrant data has been migrated off the legacy volume names and the compose name can change at no data cost.
