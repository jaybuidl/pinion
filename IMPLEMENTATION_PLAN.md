# Implementation Plan

Phased build order with exit criteria per phase. Designed to ship value early and delay optional complexity until measurements justify it.

Expected overall timeline: Phase 1-3 are a few weeks of engineering for one engineer familiar with the stack. Phases 4-5 are optional and contingent on measurements.

---

## Phase 0 — Foundations

**Goal:** Pre-work that unblocks every later phase.

**Deliverables:**

1. **Repository scaffold.** Language choice (likely TypeScript or Go, matching Atlas's existing stack), project structure, CI, linting, deployment pipeline.
2. **Filebase integration validated.** Reference client for `pin-by-CID` and `unpin-by-CID`. Confirm async semantics, provider-hint support, failure modes. A throwaway script that pins a known CID and verifies.
3. **Database schema migrated.** Tables from ARCHITECTURE.md §Data Model live in a dev environment.
4. **Subgraph query clients.** For each active Kleros subgraph, a typed client with retry and timeout handling. Start with the arbitrator subgraph on mainnet (example endpoint in DECISIONS.md D3).
5. **Metrics and logging infrastructure.** Whatever Atlas uses (Prometheus/Grafana, Datadog, etc.) — this project will emit a lot of metrics and they should land somewhere useful from day one.

**Exit criteria:**

- Can pin a CID via Filebase programmatically end-to-end.
- Can query the mainnet arbitrator subgraph for a known dispute and extract the arbitrable address.
- Schema migrations apply cleanly on a fresh database.
- Metrics from a "hello world" service show up on dashboards.

---

## Phase 1 — Core happy path: pre-register + walker + GC

**Goal:** A working pre-register endpoint that pins content, walks known schemas, and garbage-collects abandoned registrations.

**Deliverables:**

1. **Pre-register endpoint.**
   - `POST /v1/pre-register` with CID validation, blacklist check, per-IP rate limits, pending-row creation, enqueue-to-pipeline.
   - `GET /v1/cid-status/:cid` for polling.
2. **Pinning pipeline (minimal).**
   - Single-worker queue consumer. Handles `(cid, kind)` messages.
   - Calls Filebase pin-by-CID, polls for completion.
   - On verified, updates `pinned_content`.
   - Retry logic with backoff.
3. **Recursive URI walker.**
   - Schema definitions for at least `metaevidence_v1`, `evidence_v1`, `dispute_template_v2`, `curate_item_v2` (for the last, start with shape-detection in log-only mode).
   - Bounded traversal: depth, per-CID size, per-root byte budget.
   - `cid_children` cache lookup.
4. **GC worker.**
   - Periodic job (every 5 minutes).
   - Expires pending rows past TTL, refcount handling, unpin via Filebase, blacklist insertion.
   - Subgraph recheck before unpinning (D7).
5. **Blacklist enforcement in pre-register.**

**Exit criteria:**

- End-to-end test: upload to Pinata, call pre-register with `metaevidence_v1`, within 10s see the root CID pinned on Filebase, within 30s see attachments pinned, verify all reachable via Atlas IPFS CDN.
- GC test: pre-register a CID without any on-chain reference, wait (or time-travel) past TTL, verify unpinned and blacklisted.
- Retry test: fake a Filebase transient failure, verify retry and eventual success.
- Walker bound tests: construct a metaevidence with 100 nested references, verify the byte budget is respected.

**Out of scope for Phase 1:**

- Reconciliation (Phase 2).
- CDN bandwidth policy (Phase 3).
- Event watcher (Phase 4, maybe).
- Optional auth tier (Phase 5, maybe).

---

## Phase 2 — Subgraph reconciliation

**Goal:** Close the durability guarantee for clients that don't pre-register.

**Deliverables:**

1. **Reconciliation worker.**
   - Plugin architecture: each subgraph source is a module implementing `get_new_cids_since(cursor) → [(cid, kind, source)]`.
   - Cursor persistence in `subgraph_cursors`.
   - Periodic loop (every 30-60s), configurable per source.
2. **Subgraph source modules** for:
   - Arbitrator subgraph (mainnet and all deployed chains). Surfaces dispute templates and indirectly arbitrable addresses.
   - DisputeTemplateRegistry indexing. Surfaces template URIs.
   - Curate subgraphs per chain. Surfaces list policy URIs and item URIs.
   - Per-product evidence feeds where needed (e.g. PoH evidence).
3. **Promotion logic.**
   - Reconciliation-discovered CID matches pending row → promote to confirmed, move to protocol pool.
   - Reconciliation-discovered CID not yet in pinned_content → enqueue with kind hint.
4. **Lag monitoring and alerting.**
5. **Admin tool: backfill from historical subgraph state.** Useful at launch to pin existing evidence from past disputes if desired.

**Exit criteria:**

- Third-party client upload test: upload to Pinata, submit evidence tx without calling pre-register, verify Atlas pins within 2 minutes of tx inclusion.
- Reconciliation idempotency: kill the worker mid-loop, restart, verify no CIDs are missed or double-processed.
- Subgraph outage simulation: make one subgraph return errors, verify other reconciliation sources continue normally and alerts fire.
- Lag threshold test: artificially delay one subgraph's response, verify lag metric reflects reality.

---

## Phase 3 — Bandwidth policy + public status

**Goal:** Tighten abuse surface and expose operational state.

**Deliverables:**

1. **CDN bandwidth policy layer.**
   - Exact implementation depends on Atlas's CDN architecture. If Cloudflare Worker sits in front of Filebase, this is a Worker script calling a status lookup and applying rate-limit headers.
   - Enforces per-CID rate limits on pending pool, generous on protocol pool.
2. **`GET /v1/status` endpoint.** Public operational state.
3. **Admin dashboards.**
   - Pending pool health (rows, bytes, per-IP distribution).
   - Pinning pipeline throughput (enqueue rate, verify latency percentiles).
   - Subgraph lag per source.
   - Blacklist growth.
4. **Runbooks.**
   - "Filebase is down" — what happens, what to do.
   - "One subgraph is stuck" — same.
   - "Abuse spike detected" — how to triage and mitigate.
   - "Manual pin/unpin" procedure.

**Exit criteria:**

- Bandwidth policy test: pre-register a CID, download it via the CDN repeatedly from one IP, verify rate limits kick in after expected threshold.
- Status endpoint reflects actual state during induced outages.
- Operator can answer "is Atlas healthy" in <30s via dashboard.

---

## Phase 4 — (Conditional) Event watcher

**Goal:** Close the 30-60s subgraph lag window for post-tx discovery of non-pre-registering third-party clients.

**Trigger:** Phase 3 measurements show that >X% of third-party content has pin-verification lag correlated with CDN unavailability events, AND the lag can't be solved by reducing subgraph poll interval or self-hosting an indexer.

**If those conditions aren't met, skip this phase entirely.**

**Deliverables (if pursued):**

1. WebSocket `eth_subscribe` logs consumer per chain.
2. Topic-only filtering (not address-based) to avoid needing a contract whitelist — decoder fires on any log matching Kleros event signatures.
3. Subgraph-backed confirmation: decoder enqueues `(cid, kind, candidate_source_address)`, pipeline verifies `candidate_source_address` is a known Kleros contract via subgraph before pinning.
4. Gap-fill on reconnect via `eth_getLogs`.
5. Redundant subscriptions to independent RPC providers.

**Exit criteria:**

- Measured reduction in third-party post-tx pin latency to under the threshold that motivated the work.
- No false positives (non-Kleros content getting pinned).

---

## Phase 5 — (Conditional) Authenticated tier for higher quotas

**Goal:** Let trusted callers opt into higher limits.

**Trigger:** Observed legitimate usage patterns that need more than the per-IP defaults (e.g. Kleros's own frontend fleet, high-volume curate lists, enterprise integrations).

**If those needs don't materialize, skip this phase.**

**Deliverables (if pursued):**

1. Optional `Authorization` header on `/v1/pre-register` accepting a SIWE assertion or EIP-191 signed message.
2. Per-address quota configuration (admin-managed or self-service via an additional endpoint).
3. Tier logic: authenticated requests bypass IP-based limits and apply address-based limits instead.

**Explicitly does NOT:**

- Make the unauthenticated path go away.
- Reintroduce origin validation.
- Replace the existing Atlas SIWE upload endpoint.

---

## Phase 6 — (Optional) Backup pin provider for high-value content

**Goal:** Redundancy for the most critical content (e.g. high-value disputes, core policy documents).

**Trigger:** Incident analysis shows Filebase single-provider risk is materially affecting Kleros dispute resolution.

**Deliverables (if pursued):**

1. Second pin provider integration (w3up, own IPFS cluster, etc.).
2. Mirror policy: which content gets dual-pinned. Simple starting criterion: all confirmed-pool content above some on-chain stake threshold.
3. Monitoring of mirror completeness.

---

## Risks and mitigations

![Pasted image 20260422202158](./_attachments/Pasted%20image%2020260422202158.png)

### Subgraph availability dependency

**Risk:** Under D3, reconciliation is load-bearing on subgraph uptime. A multi-day TheGraph hosted service incident could stall post-tx pinning for all third-party clients.

**Mitigations:**
- Phase 0 includes monitoring; Phase 2 includes lag alerting.
- If hosted service proves unreliable, self-host indexers (additional ops cost but well-understood).
- Pre-register path is unaffected by subgraph outages.

### Filebase single-provider dependency

**Risk:** Filebase outage stalls all pinning.

**Mitigations:**
- Pinning pipeline's retry logic handles transient outages gracefully.
- Phase 6 adds redundancy if this becomes a real problem.
- Existing content already pinned stays available (Filebase outages historically affect new pins more than existing ones).

### Walker schema drift

**Risk:** Kleros products change their JSON content schemas, walker misses new URI fields, nested content not durably pinned.

**Mitigations:**
- Shape-detection logging catches unknown URI-looking values.
- Coordinate with Kleros product teams: schema changes should ping Atlas. Document this dependency.
- Periodic audit of walker logs against actual content in the wild.

### Multi-chain configuration drift

**Risk:** New Kleros deployment on a new chain, reconciliation isn't configured for it, content on that chain doesn't get pinned.

**Mitigations:**
- Configuration-driven, not code-driven: adding a chain is a config change, not a code change.
- Alert on any arbitrator subgraph that Atlas doesn't recognize producing dispute events.

### Cost of reconciliation subgraph queries

**Risk:** At scale, querying many subgraphs every 30s adds up.

**Mitigations:**
- TheGraph hosted service pricing is query-based but generally manageable at this poll rate.
- Self-hosting eliminates the cost if it matters.

### Residual pinbomb window during Phase 1

**Risk:** Pre-register is live but reconciliation isn't, meaning any content that gets pre-registered with `kind=raw` and is a pinbomb could fill up pending pool capacity without walker bounds being enough.

**Mitigations:**
- Per-IP pending-bytes quota enforced from Phase 1.
- Shorter initial TTL (24h) during Phase 1 hardening, extended once stable.
- Walker size limits apply regardless of `kind` — the per-root byte budget is the outer ceiling.

---

## Measurement plan

Useful to know what to measure so later decisions (skip/do Phase 4, tune quotas) are evidence-based.

Track from Phase 1 onward:

- **Pre-register adoption rate.** Fraction of on-chain-referenced CIDs that were pre-registered vs. discovered only via reconciliation. Informs Phase 4 decision.
- **Time-to-pin-verified distribution** by path (pre-register, reconciliation). P50, P95, P99.
- **Pre-register abandonment rate.** Fraction of pending rows that expire vs. get confirmed. High abandonment indicates either abuse or client bugs.
- **Walker budget-hit rate.** How often the per-root byte budget is reached. Near-zero is healthy; elevated warrants investigation.
- **Per-IP skew.** Distribution of pre-register volume across IPs. Heavy skew suggests ecosystem dominance or abuse; flat suggests healthy diversity.
- **Reconciliation catch-up time after restart.** How long to drain backlog from a cold start. Informs capacity planning.

---

## Handover points

When this project reaches steady state, it integrates with:

- **Kleros SDK.** The SDK should call pre-register automatically on behalf of apps. Coordinate with SDK maintainers to add this.
- **Kleros frontends.** Existing frontends that upload via the SIWE endpoint should migrate to the "upload anywhere + pre-register" pattern on their own schedule; no forced migration.
- **Kleros CLI / MCP / agent skills.** Document the pre-register API in docs.kleros.io, include it in SDK templates.
- **Kleros product teams.** Document the schema-coordination dependency: new content types need walker schemas.
- **Atlas ops.** Runbooks, alerts, dashboards (Phase 3 deliverables).

---

## What to build next (immediate next steps)

If you're picking this up right now:

1. Read README.md, DECISIONS.md, ARCHITECTURE.md in that order.
2. Resolve the Phase 0 open questions:
   - Language and stack for the service (match Atlas conventions).
   - Exact Filebase API semantics.
   - Audit of active Kleros subgraphs and URI-bearing entities.
   - Chain list.
3. Set up repository scaffold and CI.
4. Build Filebase reference client and validate end-to-end pin of a known CID.
5. Begin Phase 1 proper with pre-register endpoint skeleton.
