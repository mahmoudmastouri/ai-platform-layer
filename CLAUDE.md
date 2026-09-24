# ai-platform-layer

Docker Compose source for the shared AI platform layer on CT 210 (ai-platform-01).
Read `README.md` first. Decisions live in `docs/adr/`.

## Rules for every session in this repo

- **Platform layer only.** This repo holds compose files, per-service config and
  helper scripts. No application code, no Terraform, no Kubernetes files.
- **Never run terraform.** Terraform lives in a private homelab repo and deploys this
  repo. Do not add `.tf` files here and do not run `terraform` from here.
- **Never change the compose top-level `name:`** (`ai-platform-stack`), and never
  rename an existing volume or the default network. The name and the volume names
  are how the running SeaweedFS and Qdrant data are adopted (ADR-025). Volume names
  render as `ai-platform-stack_<volume>`; check with `docker compose config`.
- **Pin every image to an exact tag. Never `latest`.** The gateway image is also
  pinned by sha256 digest, and a digest is only accepted after it has been verified
  (cosign for LiteLLM).
- **No MinIO in any form**, including as a client image, a sidecar or an example
  (ADR-002). SeaweedFS is the object store.
- **No Kubernetes files until a cluster exists.**
- **Every service has `mem_limit`, and the sum of all `mem_limit` values stays at or
  under 8 GiB**, CT 210's cgroup limit (ADR-024). Count profile services and one-shot
  init services.
  Check with `scripts/check-mem-budget.sh` before every commit that touches compose.
- **Secrets only in `compose/.env`.** It is gitignored and never committed. Nothing
  secret goes into a tracked file, an image, a log line or an ADR.
  `compose/.env.example` lists every variable with no values.
- **ADRs** go in `docs/adr/` as `ADR-0NN-slug.md` with these sections, in order:
  Context, Options considered, Decision, Reasoning, Rejected and why, Consequences,
  Revisit trigger.
- **No em dashes in docs.**

## Working here

- Validate with `docker compose -f compose/docker-compose.yml config`. Use
  `--env-file` with a scratch file outside the repo when `compose/.env` is absent.
- Deployment is done by the operator through Terraform after a push. Sessions may
  inspect the host read-only over SSH, and may not change it.
- Do not modify `ai-platform-stack`. It is no longer the platform source for CT 210.
- One commit per stage of work, then push.
