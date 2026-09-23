# ADR-018: LLM failover in a LiteLLM gateway

**Date:** 2026-09-24
**Status:** Draft
**Tags:** #infra #ai-platform #evals

## Context
Several projects on CT 210's platform call hosted models, and a run that fails because one provider is slow or down is a lost run. Failover has to behave the same for every project and has to be testable on demand, because an untested fallback is a guess. The provider keys for Anthropic, OpenAI and OpenRouter are also the most valuable secrets in the environment. The status stays Draft until the post-deploy acceptance run has exercised every path below.

## Options considered
### Option A: The LiteLLM SDK Router inside each application
Each app imports `litellm`, builds a `Router` with fallbacks, and holds the provider keys.

### Option B: A hand-written fallback chain
A small shared function that tries provider A, then B, then C with a timeout on each.

### Option C: OpenRouter only
One key, one endpoint, with OpenRouter's own routing and fallbacks across the providers behind it.

### Option D: A LiteLLM proxy as a gateway on CT 210
One container in the platform layer, reached over HTTP with one master key, holding the provider keys and the fallback configuration.

## Decision
Chose Option D. The gateway is the official LiteLLM proxy image `ghcr.io/berriai/litellm` at `v1.102.1`, pinned by digest `sha256:87f34979b9f8cb274fac90ca8a4fdda07d8480de22755562a26adeb95ce20d02`, which was verified with cosign against the signing key published at BerriAI/litellm commit `0112e53`. It runs in config-file mode with no database, no logging callbacks, the admin UI disabled and telemetry off, on port 4000 on the LAN address, behind a master key.

| Model group | Deployments, in fallback order | Price per million tokens, in / out |
|---|---|---|
| `generator` | `anthropic/claude-haiku-4-5-20251001`, then `openai/gpt-6-luna`, then `openrouter/meta-llama/llama-3.3-70b-instruct` | $1.00 / $5.00, $0.10 / $0.50, $0.10 / $0.32 |
| `judge` | `openai/gpt-5.4-mini`, no fallback | $0.75 / $4.50 |
| `embedder` | `openai/text-embedding-3-small`, 1536 dimensions | $0.02 in |
| `generator-fault-timeout` | fault stub that hangs, then the `generator` chain | none |
| `generator-fault-5xx` | fault stub that returns 503, then the `generator` chain | none |

Router settings are `num_retries: 1`, `allowed_fails: 3`, `cooldown_time: 60`, and an explicit timeout on every deployment: 30 s for haiku and gpt-6-luna, 45 s for OpenRouter, 90 s for the judge, 15 s for embeddings, and 5 s for the stub. The stub is a `python:3.13.15-slim` container with an inline script under the compose profile `faults`, capped at 64m. The gateway is capped at 768m.

## Reasoning
**Keys in one place.** With the gateway, applications hold one gateway key and the three provider keys sit only in `compose/.env` on CT 210. With Option A every application environment holds all three provider keys and resolves `litellm` from PyPI at install time. On 24 March 2026 versions 1.82.7 and 1.82.8 of the `litellm` PyPI package were published with a malicious payload that harvested credentials ([LiteLLM's security update](https://docs.litellm.ai/blog/security-update-march-2026), [tracking issue](https://github.com/BerriAI/litellm/issues/24518)). An application that installed either version would have exposed every provider key in its environment. A pinned image digest is resolved once, by hand, and checked against a signature.

**One place to define and test failover.** Fallbacks, timeouts and cooldowns live in `compose/litellm/config.yaml`. The two fault groups make both failure modes reproducible on demand: one hangs past its 5 s timeout, the other answers 503, and each must still return 200 through the `generator` chain. Fallbacks are separate model groups on purpose, because LiteLLM moves between groups on failure and separate groups let each deployment be called directly in acceptance.

**Three independent paths for `generator`.** Anthropic, OpenAI and OpenRouter fail independently. OpenRouter is last, so it is a third path and not the only one.

**No fallback for `judge`.** A judge that silently changes model changes the score distribution of every eval that follows. The only alternative in reach is an Anthropic model, which the brief excludes and which would share a vendor with the primary generator. An outage of the judge fails the eval run loudly instead.

**Model choices, checked on 2026-09-24.** `claude-haiku-4-5-20251001` is listed as Active on Anthropic's deprecations page, with a tentative retirement date of not sooner than 15 October 2026 and at least 60 days' notice. `gpt-5-nano` and `gpt-5-mini` are scheduled for shutdown on 11 December 2026, so they were not chosen. OpenAI's models page lists `gpt-6-luna` at $0.10 in and $0.50 out as its most efficient model, which makes it the cheapest current small chat model. `gpt-5.4-mini` is current and is the judge. Prices for gpt-6-luna are set by hand in the config because LiteLLM 1.102.1 has no entry for it.

## Rejected and why
**Option A, the SDK Router in each application.** Every application holds every provider key and imports a package from PyPI, which was compromised on 24 March 2026. Failover behaviour is also defined once per application, so it drifts, and cooldown state is per process, so one application cannot learn from another's failures.

**Option B, a hand-written chain.** It re-implements timeouts, retry counts, cooldown after repeated failures, and cost accounting, and each of those is a place to be wrong that the fault tests would have to cover for every copy. A chain that has no cooldown keeps sending traffic to a provider that is down for the full timeout on every call.

**Option C, OpenRouter only.** One vendor becomes the outage domain. If OpenRouter is down, every model is down with it even while Anthropic and OpenAI are up. Its own routing spreads across providers behind it, which does not help when the front door is the failure. It stays in the design as the last fallback, where it adds a path and removes none.

## Consequences
- **An extra network hop** on every call. Its cost has not been measured. The acceptance run reports elapsed time for the direct calls.
- **A single gateway container.** If it is down, every project is down, and this is a new single point of failure in place of many independent ones. It has a healthcheck and `restart: unless-stopped`, and nothing more.
- **Fallbacks are visible only in response headers.** `x-litellm-model-group` names the group that answered and `x-litellm-attempted-fallbacks` counts the fallbacks tried. The response body looks the same. An application that records which model produced an answer must read those headers, and an eval that ignores them can score a fallback model's output as the primary's.
- **An AWS deployment needs the gateway as a sidecar.** That is one more container to pin by digest and verify there.
- **No database, so no per-application keys, budgets or spend history.** Every caller shares one master key. Cost is available per response from `x-litellm-response-cost` and nowhere else.
- **`drop_params` is on.** A parameter a provider does not support is dropped without an error, which lets one request shape cross providers and also hides a parameter that had no effect.
- **The gpt-6-luna deployment is the least verified.** It first appeared on OpenRouter's list on 22 September 2026, LiteLLM 1.102.1 has no entry for it, and its parameter handling is untested here. The acceptance run calls it directly. `openai/gpt-5.6-luna`, which is in LiteLLM's price table at $0.20 in and $1.20 out, is the replacement to try if that call fails.
- **The 768m cap is an estimate, not a measurement.** The layer's caps sum to 7104 MiB of the 7168 MiB budget, so there is 64 MiB to give back if the gateway needs more.
- **The fault groups are in the production config** and appear in `/v1/models`. They are harmless without the stub, since they fail to connect and fall back the same way.

## App-level retry classification
To be written. It should say which failures an application retries itself and which it lets the gateway handle or surfaces, and it needs measured data from real runs first. Questions it has to answer:
- Which gateway status codes are safe for an application to retry, given the gateway has already retried once and fallen back.
- Whether an application retries a 200 that carries a fallback model's answer when the run requires a specific model.
- How an application distinguishes a gateway failure from a provider failure the gateway passed through.
- What idempotency an eval run needs so a retry does not double-count a scored sample.

## Revisit trigger
Reopen when any of the following occurs:
1. Anthropic announces retirement of `claude-haiku-4-5-20251001`. The primary model changes, and the tested order of the chain changes with it.
2. The gateway is OOM-killed, or its measured steady-state memory exceeds 768m.
3. An application needs its own key, budget or spend history. That needs a database, which this decision excludes.
4. A second security incident affects LiteLLM's images or signing key, or the signature stops verifying for a release.
5. The measured overhead of the extra hop is large enough to matter to an eval's runtime.
