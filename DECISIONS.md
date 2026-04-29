# Decision Log

Architectural decisions with rationale. Read this before ARCHITECTURE.md. Each decision has a `Status`, `Context`, `Decision`, `Consequences`, and (where relevant) `Alternatives Considered`.

If you're considering reversing any of these, the rationale sections document what was explored. Many of them are not obvious and the reasoning is load-bearing.

---

## D1 — Pin-on-reference over SIWE-only upload

**Status:** Accepted.

**Context.** Historically the recommended path for Kleros-ecosystem clients to pin evidence/metaevidence was Atlas's SIWE-gated upload endpoint. Two concerns kept being bundled: the *upload* (bytes in) and the *durability commitment* (bytes kept). This created friction for non-browser clients and abuse surface for the endpoint.

We considered:
- **Option A:** Keep SIWE upload as the canonical path. Require Kleros clients to authenticate and upload through Atlas.
- **Option B:** Let everyone use third-party providers (Pinata, w3up, own nodes). Accept that durability is on them.
- **Option C:** Split upload from durability. Clients upload wherever. Atlas watches for on-chain references and pins defensively.

Option A has continuous abuse-policing overhead and poor agent UX. Option B loses the durability guarantee that makes Kleros evidence trustworthy (users could delete their Pinata pin, closing their account, etc.).

**Decision.** Option C. Atlas pins content that has been consecrated by a Kleros protocol interaction, regardless of where it was originally uploaded.

**Consequences.**
- The "how do we rate-limit the upload endpoint" problem disappears — the natural rate limit is the gas cost of the on-chain reference.
- Clients get to choose their upload path freely, including x402-based agentic flows.
- We must solve a new problem: the race window between upload to a third-party provider and the on-chain tx landing (see D2).
- The existing SIWE upload endpoint remains live but demoted from "canonical path" to "convenience shortcut."

---

## D2 — Pre-register endpoint to close the race window

![[Pasted image 20260422201835.png|900]]

**Status:** Accepted.

**Context.** Under D1, Atlas discovers CIDs to pin only after they appear in an on-chain reference. This creates a race: if a user uploads to Pinata, then their client sends the on-chain tx, there is a window — upload to tx inclusion, plus tx inclusion to Atlas-pin-verified — during which the user could delete their Pinata pin. If no one else has fetched the CID, Atlas can't resolve it when it tries.

**Decision.** Expose a pre-register endpoint. Clients (SDK, frontend, CLI, MCP) call it with the CID they're about to reference before or in parallel with sending the on-chain tx. Atlas starts fetching and pinning immediately, so by the time the tx lands the content is already durable.

**Consequences.**
- The race window for any client that pre-registers is effectively zero.
- Pre-registered CIDs that never get referenced on-chain must be garbage-collected (see D4).
- We need an abuse model for an open pin-by-CID endpoint (see D5, D7).
- Clients that don't pre-register still work, just with a longer latency window before pin-verified (covered by reconciliation; see D3).

---

## D3 — Subgraph reconciliation as primary post-tx discovery

**Status:** Accepted (pivot from earlier design).

**Context.** An earlier revision of this design proposed a WebSocket-based event watcher as the primary post-tx discovery mechanism, specifically to minimize detection latency and thereby shrink the race window. Subgraph polling was rejected on latency grounds (10-60s indexing lag).

The introduction of pre-register (D2) changed the latency budget. The critical path for race-window closure is now *pre-tx*, not post-tx. Post-tx discovery's only remaining job is catching clients that didn't pre-register — a narrower, more tail-end case where 30-60s detection latency is acceptable.

Simultaneously, Kleros already operates production subgraphs that index everything needed for discovery:
- Arbitrator subgraph: `disputeID → arbitrable`, dispute creation events
- Curate subgraph: factory deployments, list state, item submissions
- Per-arbitrable evidence subgraphs: `Evidence` and `MetaEvidence` events
- DisputeTemplateRegistry indexing: `templateId → templateUri`

Example working query pattern:
```graphql
# https://api.studio.thegraph.com/query/61738/kleros-display-mainnet/version/latest
{
  dispute(id: 1600) {
    disputeIDNumber
    arbitrated
  }
}
```
Returns `arbitrated: "0xc5e9ddebb09cd64dfacab4011a0d5cedaf7c9bdb"` — the third-party arbitrable address we'd otherwise have had to discover via a `DisputeCreation` event watcher.

**Decision.** Use subgraph polling as the primary post-tx discovery mechanism. Poll every 30-60s, union the CID sets from all relevant subgraphs, diff against our pinned-content table, enqueue missing CIDs. Defer the WebSocket event watcher (see D10).

**Consequences.**
- The contract whitelist complexity from the earlier design (static list, factory-deployed list, third-party arbitrables via `DisputeCreation`, per-contract-type event decoders) is largely delegated to TheGraph. This is a significant simplification.
- Subgraph availability becomes load-bearing. Hosted service incidents translate to reconciliation lag. Mitigation: alert on lag, run own indexer as backup if needed.
- Subgraph schema changes can break reconciliation. Pin subgraph versions in queries; monitor for breakage in CI.
- We become dependent on Kleros subgraphs being complete and correct for this use case. If a product team ships a new arbitrable without subgraph coverage, reconciliation won't see it. Document this dependency clearly for Kleros product teams.

**Alternatives considered.**
- WebSocket event watcher as primary: rejected because pre-register absorbs the latency requirement, and the implementation cost of a correct watcher (contract whitelist, dynamic discovery via factory and arbitrator events, per-type event decoders, reorg handling) is high relative to its remaining value.
- Subgraph + watcher hybrid: deferred. Add the watcher later if measurements show unacceptable gaps in subgraph-only coverage.

---

## D4 — Two-pool state model with TTL-based GC

**Status:** Accepted.

**Context.** Pre-registered CIDs that never see an on-chain reference must be unpinned to prevent the endpoint from being a free IPFS service. But naive GC breaks in two ways: a tx landing seconds after TTL could lose legitimate data, and a CID might be pre-registered by multiple parties (racing to submit the same file, mirroring).

**Decision.** Two logical pools with a per-(CID, requester) state machine.

*Pending pool* holds pre-registered CIDs that haven't been referenced on-chain. Bounded size, TTL 24-72h (start at 72h, tune on data), quota-managed per requester.

*Protocol pool* holds CIDs that have been referenced on-chain. Durable. Content flows from pending → protocol on confirmation (the watcher or reconciliation observes the reference).

State machine per `(cid, requester_address_or_ip)`:
- `pending` on pre-register
- `fetching` while Filebase pin-by-CID is in progress
- `confirmed` when reconciliation or watcher sees on-chain reference
- `expired` when TTL hits without confirmation

Unpin logic: a CID is unpinned only when the last pending row for it expires AND it's not in the protocol pool. Reference counting per CID handles the multi-requester case.

**Consequences.**
- Storage cost of abuse is bounded by `TTL × per-CID size cap × concurrent pending cap per requester`.
- Pre-registering an already-confirmed CID is a no-op on storage (just increments an observation counter).
- GC job runs periodically, is idempotent, and is cheap.
- See D7 for the `check-subgraph-before-unpin` safeguard.

---

## D5 — Open (unauthenticated) pre-register endpoint

**Status:** Accepted.

**Context.** Initially we considered SIWE-gating the pre-register endpoint, reasoning that authentication provides per-address rate limiting and abuse attribution. On reflection:

- SIWE's main value in the existing Atlas endpoint is paired with origin validation, and origin validation exists because browsers auto-attach credentials to cross-origin requests (CSRF). Neither concern applies to CLI tools, MCPs, or bots.
- SIWE requires wallet key material accessible to the tool and a signing flow, which is real friction for ambient zero-config agents and defeats the UX benefit of x402 on the upload side.
- Pre-register only triggers a bounded amount of work: Filebase pin-by-CID with per-CID size caps. The abuse envelope is narrow by construction.
- GC (D4), blacklist-on-expiry (D6), and asymmetric bandwidth policy (ARCHITECTURE.md §Abuse Model) structurally bound abuse without needing identity.

**Decision.** Pre-register is open. No SIWE, no origin validation, no wallet signature required.

An optional signed-attestation tier MAY be added later: callers who sign an EIP-191 message or a SIWE assertion get higher quotas, longer TTLs, and potentially generous bandwidth on pending content. This tier is strictly additive; the unauthenticated happy path remains.

**Consequences.**
- Agents using x402-based upload flows can also use pre-register without additional auth setup. Full zero-config UX.
- Abuse mitigation moves entirely to quotas, blacklists, and bandwidth policy. We MUST implement these correctly or the endpoint is a free pin service.
- We cannot attribute abuse to Kleros-ecosystem addresses. That's fine; we attribute to IPs and behavior patterns instead.

**Alternatives considered.**
- SIWE-required: rejected for non-browser UX friction.
- SIWE-or-captcha: captchas defeat agent use case, which is a primary target audience.
- IP-allowlist for known clients: doesn't scale, closes the ecosystem.

---

## D6 — Blacklist on TTL expiry

**Status:** Accepted.

**Context.** Under D4 + D5, an attacker could pre-register the same CID, let it expire, pre-register it again, and effectively use pre-register as a rolling free pin. Storage-wise they never exceed the cap; bandwidth-wise they're getting CDN service for unconfirmed content (mitigated by asymmetric bandwidth policy, see ARCHITECTURE.md §Abuse Model, but still undesirable).

**Decision.** When a pending CID is unpinned due to TTL expiry, its CID is added to a blacklist. Subsequent pre-register calls for that CID are rejected.

A CID can be removed from the blacklist only by:
- Being referenced on-chain and observed by reconciliation (then it's pinned via the post-tx path, not via pre-register). Blacklist entry is cleared, content moves into protocol pool.
- Manual admin override (e.g. known-good content, accidental expiry).

**Consequences.**
- Rolling-window abuse is structurally blocked.
- A legitimate user whose tx genuinely fails post-upload (out-of-gas, reverted, etc.) and doesn't retry within TTL loses the ability to pre-register the same CID again. They'd need to re-upload to get a different CID, or reference it on-chain (which then triggers the post-tx path). Both are acceptable escape valves.
- Blacklist is per-CID, not per-requester. A bad actor can't reuse the same content, but can upload fresh content — bounded by per-requester quotas.

---

## D7 — Check subgraph before unpinning expired content

**Status:** Accepted.

**Context.** A GC job that unpins strictly on `now > pending.expires_at` has an edge-case data-loss risk: a legitimate tx landing 30 seconds before the TTL, not yet reflected in our confirmed set due to subgraph indexing lag, would get its pending row expired and its content unpinned. The next reconciliation cycle would discover the on-chain reference and try to re-pin, but the CID is now on the D6 blacklist and/or the content is gone.

**Decision.** GC always re-checks the subgraph for the CID immediately before unpinning. If subgraph shows a confirmed on-chain reference, GC promotes the row to `confirmed` and moves the CID to the protocol pool instead of unpinning. Blacklist entry is not added in this case.

**Consequences.**
- GC is slightly slower (one subgraph query per expiring row, batched). Acceptable — GC is not latency-sensitive.
- Edge-case data loss from indexing lag is closed.

---

## D8 — Recursive URI walker is content-property, not discovery-property

**Status:** Accepted.

**Context.** Some Kleros content types are JSON that reference further IPFS CIDs:
- V1 MetaEvidence → `fileURI`, `dynamicScriptURI`, `evidenceDisplayInterfaceURI`
- V1 Evidence (envelope) → `fileURI` pointing to the actual attachment
- V2 DisputeTemplate → (schema-dependent fields)

Subgraphs do NOT walk these. They index only the top-level CID referenced on-chain. To achieve actual durability of the full content graph, Atlas must fetch these JSONs, walk them for nested IPFS references, and pin the descendants.

**Decision.** Build a shared recursive URI walker used by both pre-register and reconciliation. The walker is downstream of discovery — it runs after any top-level CID is pinned, regardless of which code path enqueued it.

Bounds (all mandatory):
- **Depth limit:** 3. Metaevidence → attachment is depth 2; anything deeper is suspect.
- **Per-CID size cap:** 50 MB by default. JSON envelopes should be tiny; attachments are bounded. Reject-and-log if exceeded.
- **Per-root byte budget:** configurable, default 500 MB. Sum of all bytes fetched under a single top-level root. Abort recursion when exceeded, flag for human review.
- **Schema awareness:** for known Kleros formats (v1 metaevidence, v1 evidence, v2 dispute templates), walk only known URI fields. For unknown formats, fall back to shape-detection but initially in LOG-ONLY mode (discover references, don't auto-pin). Promote to auto-pin per-schema once we trust the detection.

**Consequences.**
- Walker is product-aware. Adding support for a new Kleros content type means adding a schema definition to the walker.
- Dedup cache `cid → [nested_cids]` avoids re-walking the same metaevidence for every dispute using it.
- Bounds mean some pathological content may be incompletely pinned. This is strictly better than no bounds (which invites pinbombs).

---

## D9 — Content-type hint on pre-register

**Status:** Accepted.

**Context.** A client calling pre-register usually knows what kind of content the CID is (they just uploaded it). Passing that hint lets Atlas apply the right walker immediately, pinning the full content graph before the on-chain tx even lands.

**Decision.** Pre-register accepts an optional `kind` field. Initial supported values:
- `metaevidence_v1`
- `evidence_v1`
- `dispute_template_v2`
- `curate_item_v2`
- `raw` (default) — pin just the CID, no walk

A `providers` array hint is also accepted for IPFS DHT provider records (useful when the client uploaded to a non-public-DHT-announcing node).

**Consequences.**
- Well-behaved SDK clients get full content-graph durability guaranteed before tx inclusion.
- Third-party or misconfigured clients that pass `raw` or no hint still get correct behavior after reconciliation re-queues with the inferred schema (reconciliation knows the on-chain context and can infer kind).

---

## D10 — Event watcher deferred, not rejected

**Status:** Deferred.

**Context.** Earlier iterations of this design treated a WebSocket event watcher as essential. Under D3, its role collapses to "close the 30-60s subgraph lag window for clients that didn't pre-register." That may or may not be worth building.

**Decision.** Do not build the event watcher in the initial implementation. Measure what fraction of post-tx-discovered content arrived via reconciliation vs. pre-register, and measure the distribution of "on-chain reference to pin verified" latency for the reconciliation-only path. If the measurements show meaningful impact (e.g. >X% of third-party content has pin-verification lag that correlates with availability failures at the CDN), add the watcher as a Phase 4 enhancement.

If the watcher is added later, it should NOT reintroduce the contract whitelist — topic-only subscription with subgraph-based address confirmation after the fact is the correct pattern.

**Consequences.**
- Less code to maintain in the initial shipment.
- A narrow coverage gap for third-party non-pre-registering clients. Not expected to matter in practice.

---

## D11 — Do not maintain parallel indexes of on-chain state

**Status:** Accepted.

**Context.** Temptation exists to cache `disputeID → arbitrable`, `templateId → templateUri`, factory deployments, etc. locally for speed. Each such cache is a potential drift point against the subgraph.

**Decision.** Do not cache on-chain-derived mappings in Atlas's own database. Query the subgraph on demand. If subgraph query latency becomes a bottleneck, cache at the subgraph-query layer with short TTLs (minutes), not in the primary data model.

Our database stores only:
- Pinned-content state (`cid`, pinning status, refcount, pool)
- Pending-pool state (pre-register rows with TTL, requester info)
- Blacklist
- CID graph cache (parent CID → nested CIDs, for walker dedup)
- Operational telemetry

It does NOT store:
- `disputeID → arbitrable`
- `templateId → templateUri`
- Factory deployments
- Arbitrable contract lists

**Consequences.**
- Single source of truth for on-chain state.
- Subgraph query volume increases. Monitor and cache at query layer if needed.

---

## D12 — Asymmetric bandwidth policy (pending vs confirmed)

**Status:** Accepted.

**Context.** Under D5 (open endpoint), an attacker could pre-register abusive content and use Atlas's IPFS CDN as free bandwidth for 72h before GC unpins. Storage is bounded; bandwidth is not, absent policy.

**Decision.** Apply asymmetric bandwidth policy at the CDN layer:
- **Confirmed (protocol pool):** generous bandwidth. Serves the actual Kleros product use cases — jurors loading evidence, curators reviewing items, dispute UIs rendering metaevidence. Effectively unmetered.
- **Pending (pre-registered, not yet confirmed):** tight per-CID rate limit. Enough for the submitting client to verify the upload and for initial previews, not enough to serve as a free CDN. Default: a few hundred KB/s per CID, few hundred requests/day per CID.

**Consequences.**
- Legitimate users see no degradation — their CID confirms on-chain within minutes and unlocks full bandwidth.
- Bandwidth abuse of the pending tier becomes uneconomical.
- Implementation requires CDN-layer integration with Atlas's pinned-content state (or a synced lookup table).
