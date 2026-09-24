# ADR-022: Self-hosted Langfuse in the shared AI platform layer

> Master copy lives in the homelab infrastructure repo. Edit there, not here.

**Date:** 2026-09-23
**Status:** Draft
**Tags:** #infra #ai-platform

## Context
Langfuse was cloud-hosted (ADR-009), one Langfuse Cloud project per application. CT 210 is about to host a LiteLLM gateway that every application will route through, which makes one tracing backend for the whole platform the natural shape. CT 210 has 8 GiB and swap 0 (ADR-024), while Langfuse's self-hosting guide recommends 4 cores and 16 GiB for a VM and its Kubernetes guidance gives ClickHouse alone an 8 Gi request and a 16 Gi limit. Langfuse v4 also requires ClickHouse 25.12 or newer. The platform's premise (ADR-008, ADR-016) is that everything on it can be regenerated; a trace of a non-deterministic model run cannot be.

## Options considered
### Option A: Langfuse Cloud, one project per application
The status quo under ADR-009. No memory cost on CT 210, no state to lose, managed upgrades.

### Option B: One self-hosted Langfuse in the shared layer, blob storage on the existing SeaweedFS
Langfuse v4 (web and worker), Postgres, ClickHouse and Valkey in the existing compose project, event blobs written to a `langfuse-events` bucket in the SeaweedFS already running there, an explicit `mem_limit` on every service, and trace state treated as disposable.

### Option C: Self-hosted Langfuse with its bundled blob store
Langfuse's reference compose file ships its own S3-compatible blob-store container. Least deviation from upstream, and the path its documentation exercises most.

### Option D: Self-hosted Langfuse on its own guest sized to the recommendation
A VM or CT with 16 GiB, so Langfuse runs as documented.

### Option E: Self-hosted with backups of the Postgres and ClickHouse volumes
As Option B, plus scheduled volume backups so traces survive a CT destroy.

## Decision
Chose Option B. Images are pinned to `langfuse/langfuse` and `langfuse/langfuse-worker` 4.41.0, `clickhouse/clickhouse-server` 26.4.5.143, `postgres` 17.11-alpine3.24 and `valkey/valkey` 9.0.6-alpine3.24. Each `mem_limit` is set as follows:

| Service | mem_limit | Inner cap |
|---|---|---|
| clickhouse | 2560m | `max_server_memory_usage` = 2147483648 B (2 GiB), absolute |
| langfuse-web | 2g | `NODE_OPTIONS=--max-old-space-size=1536` |
| langfuse-worker | 1g | `NODE_OPTIONS=--max-old-space-size=768` |
| postgres | 512m | none |
| valkey | 256m | `maxmemory 200mb`, `noeviction` |
| Total | 6.25 GiB | Langfuse tier only; the whole layer is 7616 MiB against CT 210's 8192 MiB |

Media upload and batch export are off, `TELEMETRY_ENABLED` is false, ClickHouse cluster mode is off, and the org, project, API keys and first user are created from `.env` at first boot. `postgres_data` and `clickhouse_data` are named volumes that are lost when CT 210 is destroyed, and traces are declared disposable at the demo tier.

## Reasoning
**One foundation.** The LiteLLM gateway sends every model call from every project through CT 210. One Langfuse there sees all of them under one set of keys created from `.env`, where per-project cloud accounts mean one tracing setup per project and no single view across them. Headless initialization also makes the tracing backend part of the destroy-and-apply test instead of a manual sign-up that the rebuild cannot perform.

**SeaweedFS for blobs.** Langfuse writes every incoming event to S3 before it queues it, so an S3 API is mandatory, and SeaweedFS is already running with one. Its licence and maintenance status are settled in ADR-002. With media upload and batch export off, event blobs are the only S3 traffic, and a bucket on the existing store costs no extra container and no extra memory. The Langfuse event upload variables point at `http://seaweedfs:8333` on the compose network, path-style.

**Below the recommendation, with explicit caps.** The 16 GiB figure is sized for production ingest volume. This tier is a demo with one project and one operator. ADR-024 fixed CT 210 at 8 GiB because a larger CT puts VM 200 in the path of the host OOM killer, so the recommendation cannot be met, and the ADR itself names this cost. With swap 0, an unbounded service can exhaust the CT, so each service gets a `mem_limit` and a container that overruns is killed alone by its cgroup instead of taking the CT with it. ClickHouse gets an absolute `max_server_memory_usage` rather than a ratio, because the default ratio scales with whatever RAM the server detects and an absolute number does not move. The first sizing gave langfuse-web 1g with no heap setting, and it crash-looped 14 times during initialisation with `FATAL ERROR: Reached heap limit Allocation failed - JavaScript heap out of memory` at about 512 MB of heap, after the migrations had completed. The fix is 2g with `NODE_OPTIONS=--max-old-space-size=1536`, which sets the Node heap explicitly and leaves 512 MiB of the container for everything else. The worker keeps 1g with an explicit 768 MiB heap. ClickHouse pays for the extra 1 GiB: `max_server_memory_usage` drops from 2.4 GiB to 2 GiB (2147483648 B) and its `mem_limit` from 3g to 2560m.

The constraint is CT 210's 8 GiB cgroup. That limit is what protects the host from these services, and the per-service limits only allocate within it and decide which container is killed first. The Langfuse tier now sums to 6.25 GiB. With SeaweedFS, Qdrant, the gateway, its fault stub and the bucket-init job, the whole layer sums to 7616 MiB, which leaves 576 MiB of the CT for the Docker daemon, sshd and the kernel. Limits are ceilings, not concurrent use, so that is a budget and not a guarantee. These values come from a failure and a budget, not from a measurement. Measured idle and peak memory for each service is to be recorded here from the acceptance run before this ADR moves to Accepted.

**Traces as disposable.** ADR-016 says its own design is wrong the moment a byte lands on the stack that cannot be regenerated. Traces are that byte. This ADR does not pretend otherwise. It narrows the premise instead: everything the stack needs in order to function is reproducible, and traces are observational data outside that claim. Nothing in this repository reads a trace back, so losing them costs debugging history and no functionality. Backing them up would add a backup job, a restore path and a retention question to a tier whose value is that it rebuilds from `.env` alone, and none of the data yet justifies that.

## Rejected and why
**Option A, Langfuse Cloud per project.** Not rejected on quality. It is the fallback ADR-024 already names if the stack does not fit in 8 GiB, and it stays that. It loses on the shared-layer goal: the gateway would forward to as many Langfuse projects as there are applications, and the destroy-and-apply test could not cover tracing because the account and its keys live outside the environment.

**Option C, the bundled blob store.** Upstream's compose file uses MinIO for this role. The MinIO community edition was archived in April 2026 and is unpatched, and ADR-002 excludes it from this stack in any form, including as a sidecar. A second object store beside SeaweedFS would also duplicate the one already running and add its own memory cost to a budget with no slack for it.

**Option D, a 16 GiB guest.** ADR-024 shows the node cannot afford it: VM 200 has 16 GiB, the ZFS ARC is capped at 3 GiB, and pve1 has 32 GiB in total. A new 16 GiB guest is over budget on its own, and VM 200 is not this environment's to shrink.

**Option E, volume backups.** Rejected for now, not for good. There is no consumer of stored traces yet, so a backup protects data nobody depends on, and it adds a moving part that has to be tested by restore. The trigger below says when that changes.

## Consequences
- ADR-009 is superseded for the shared platform layer. Its file is not in the homelab ADR directory, so its status line is not updated by this change and needs a manual edit.
- Traces are lost on every CT destroy, and the same destroy invalidates nothing else: the org, project, keys and user are recreated from `.env`, so applications keep the same Langfuse keys.
- ADR-016's trigger 1 is consciously not tripped. It is recorded here so a reader who finds traces on the stack knows why the reproducibility claim still stands.
- Terraform must supply seven new generated secrets on top of the three in ADR-016: `NEXTAUTH_SECRET`, `SALT`, `ENCRYPTION_KEY`, the Postgres, ClickHouse and Valkey passwords, and the initial user password, plus the project key pair. They join the S3 and Qdrant credentials in local state. They must be stable across applies that keep the volumes, because Postgres and ClickHouse read their passwords only at volume initialization and changing `SALT` invalidates every API key.
- Langfuse ingestion depends on SeaweedFS being up, because event upload is mandatory. Langfuse uses the `platform` S3 identity, which has Admin rights. A narrower identity means changing SeaweedFS's generated identity file, which this change deliberately does not touch.
- SeaweedFS and Qdrant still have no `mem_limit`, contrary to the rule ADR-024 states for the stack. Fixing that changes services this ADR was told to leave alone, so it stays open.
- Signups are disabled on Langfuse, so the initialized user is the only account.
- Langfuse tags move often, roughly daily for v4 at the time of writing. The pinned tags are reviewed by hand, as with SeaweedFS.

## Revisit trigger
Reopen when any of the following occurs:
1. Any Langfuse-tier container is OOM-killed, or measured steady-state memory of the five services exceeds their combined 6 GiB budget. The fallback is Option A, per ADR-024.
2. Traces become an input to something else (an evaluation dataset, client-facing evidence, a regression baseline). That is ADR-016's first trigger, and Option E becomes the first step.
3. The node gains RAM or VM 200 shrinks (ADR-024's trigger). The caps and the 16 GiB question then get re-measured.
4. A second consumer wants to read Postgres, ClickHouse or Valkey directly. They exist only as Langfuse's backends and that boundary is part of this decision.

## Implementation notes (ai-platform-layer, 2026-09-24)
These record where this repo differs from, or completes, the text above. The master copy has not been changed.

- **SeaweedFS and Qdrant now have a `mem_limit`.** The consequence above that says they have none is closed in this repo: `seaweedfs` 224m (78 MiB measured idle, 124 MB of data) and `qdrant` 128m (40 MiB measured idle, empty storage). The whole layer, with the gateway, its fault stub and the bucket-init job, now sums to 7616 MiB against CT 210's 8192 MiB (see the Decision table and Reasoning, which carry the langfuse-web heap fix), so those two caps are tight by construction.
- **A fourth named volume, `valkey_data`.** Valkey runs with an append-only file so queued jobs survive a restart. Without a declared volume the image would create an anonymous one on every recreate. It is disposable like the other two.
- **Bucket creation is a one-shot `seaweedfs-init` service** that signs an S3 request with curl from the SeaweedFS image already on the host, so no new image and no MinIO client is involved. It carries no healthcheck because it exits; Langfuse waits on `service_completed_successfully`.
- **Secrets.** `scripts/gen-secrets.sh` generates `SALT`, `ENCRYPTION_KEY`, `NEXTAUTH_SECRET`, the Postgres, ClickHouse and Valkey passwords, the initial user password and the project key pair into `compose/.env` without overwriting existing values. If Terraform generates them instead, as the Consequences describe, it must write the same variable names.
- **Measured idle memory** for the five Langfuse-tier services is still to be recorded from the post-deploy acceptance run. The status stays Draft until it is.
