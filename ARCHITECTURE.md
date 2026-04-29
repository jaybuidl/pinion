# Architecture

Full design. Assumes you've read README.md and DECISIONS.md.

## System overview

![Pasted image 20260422200548](./_attachments/Pasted%20image%2020260422200548.png)

```
                 ┌──────────────────────────────────┐
  SDK/CLI/MCP    │                                  │
  Frontend ─────▶│  Pre-register endpoint  (open)   │─────┐
                 │                                  │     │
                 └──────────────────────────────────┘     │
                                                          │
  Kleros                                                  ▼
  subgraphs ◀──── Reconciliation worker ──────▶ ┌───────────────────┐
                      (every 30-60s)            │                   │
                                                │ Pinning pipeline  │
                                                │  - dedup          │
                                                │  - schema detect  │
                                                │  - recursive walk │
                                                │  - Filebase pin   │
                                                │                   │
                                                └───────────────────┘
                                                          │
                                                          ▼
                                                ┌───────────────────┐
                                                │  Atlas storage    │
                                                │  (Filebase + CDN) │
                                                └───────────────────┘
                                                          ▲
                                                          │
                                                GC worker ┘
                                                (periodic)
```

Five logical components:

1. **Pre-register endpoint** (HTTP). Accepts CID + hints, enqueues for pinning, creates a pending row.
2. **Reconciliation worker**. Polls subgraphs, diffs against pinned set, enqueues missing.
3. **Pinning pipeline**. Shared by (1) and (2). Handles dedup, Filebase pin-by-CID, recursive walking of JSON content types, refcount management.
4. **GC worker**. Periodically scans expired pending rows, re-checks subgraph, either promotes to confirmed or unpins and blacklists.
5. **CDN bandwidth policy layer**. Serves confirmed content generously, pending content tightly.

Each is independently scalable. The pinning pipeline is the shared bottleneck and should be designed for horizontal scale from day one (work queue with idempotent workers).

---

## Component specifications

### Pre-register endpoint

**Interface.**

```
POST /v1/pre-register
Content-Type: application/json

{
  "cid": "QmPChd2hVbrJ6bfo3WBcTW4iZnpHm8TEzWkLHmLpXhF68A",
  "kind": "metaevidence_v1" | "evidence_v1" | "dispute_template_v2"
        | "curate_item_v2" | "raw",
  "providers": ["/ip4/.../p2p/12D3Koo..."]   // optional DHT hints
}

→ 202 Accepted
{
  "status": "pending" | "already_confirmed" | "fetching",
  "cid": "QmPC...",
  "ttl_seconds": 259200,
  "expires_at": "2026-04-25T18:07:00Z"
}

→ 400 Bad Request    (malformed CID)
→ 403 Forbidden      (CID on blacklist)
→ 429 Too Many Requests  (rate limit exceeded)
→ 413 Payload Too Large  (after fetch start, if content exceeds size cap)
```

**Semantics.**

- Idempotent per CID. Repeated calls on a still-pending CID extend nothing and return the existing `expires_at`. Repeated calls on a confirmed CID return `already_confirmed`. No state is disturbed.
- Synchronous work on the request path is minimal: validate CID, check blacklist, check quotas, enqueue to pinning pipeline, write pending row, respond. Filebase fetch happens asynchronously.
- The endpoint does NOT wait for pin verification before responding. Clients can poll a status endpoint (below) if they care about verified state.

**Status endpoint.**

```
GET /v1/cid-status/:cid

→ 200 OK
{
  "cid": "QmPC...",
  "status": "unknown" | "pending" | "fetching" | "confirmed" | "expired",
  "pinned": true | false,
  "pool": "pending" | "protocol" | null,
  "first_seen_at": "2026-04-22T18:07:00Z",
  "confirmed_at": "2026-04-22T18:09:23Z"
}
```

Used by jurors, curators, downstream tools, and internal dashboards.

**Rate limits.** Per-IP, rolling window. Generous defaults; tighten if observed abuse:
- 60 pre-register calls / minute
- 1000 pre-register calls / day
- 10 concurrent pending rows per IP
- 500 MB total pending bytes per IP

Behind a CDN/proxy, use `CF-Connecting-IP` or `X-Forwarded-For` from a trusted hop. Do not trust raw headers without a trusted hop.

### Reconciliation worker

**Loop.** Every 30-60s (configurable per subgraph):

1. For each watched subgraph, query for CIDs referenced since last cursor. Store cursor per (subgraph, chain).
2. Union discovered CIDs across subgraphs.
3. Diff against `pinned_content` table. For each CID not in the protocol pool, enqueue to pinning pipeline with appropriate `kind` hint (inferred from which subgraph/event it came from).
4. For each CID that's also in the pending pool, promote to confirmed. Clear any blacklist entry.
5. Advance cursor atomically with the pin-enqueue. Retrying the whole loop after failure must not double-process or skip CIDs.

**Subgraphs to query.** (Verify exact URLs and schemas during implementation; list is representative.)

- Arbitrator subgraph (per chain): disputes, their `arbitrated` addresses, `templateId`s.
  - Example working endpoint: `https://api.studio.thegraph.com/query/61738/kleros-display-mainnet/version/latest`
- DisputeTemplateRegistry indexing: `templateId → templateUri` mapping and historical changes.
- Curate subgraph (per chain): factory-deployed list addresses, list metadata URIs, item submission URIs.
- Per-arbitrable evidence subgraphs (per chain): `Evidence` events with URIs, `MetaEvidence` events with URIs (V1).

Many Kleros products have dedicated subgraphs. The reconciliation worker should have a plug-in architecture where each subgraph source is a module implementing: `get_new_cids_since(cursor) → [(cid, kind, source)]`.

**Cursor persistence.** Per (subgraph, chain). Typically block number or an indexer-native cursor. Store in `subgraph_cursors` table. Commit cursor only after CIDs are successfully enqueued.

**Kind inference.** Each subgraph source knows what kind of content it surfaces. Arbitrator's `dispute.templateUri` → `dispute_template_v2`. Evidence events from a V1 arbitrable → `evidence_v1`. Curate item submissions → `curate_item_v2`. Pass this to the walker so it knows which schema fields to follow.

**Failure handling.** Any single subgraph being down does NOT block reconciliation of others. Log, alert if lag exceeds threshold (e.g. 5 minutes for arbitrator), continue with remaining sources.

### Pinning pipeline

**Queue-based, idempotent workers.** Input is `(cid, kind, source, parent_cid?, depth)`. Output is state transitions on `pinned_content` and new queue entries for nested CIDs.

**Worker flow.**

1. Check `pinned_content` for CID. If present and `status ∈ {pinned, fetching}`, return early — idempotent no-op.
2. Check blacklist if `source == pre-register`. Reject if present. (Reconciliation-sourced calls bypass blacklist — on-chain reference overrides.)
3. Upsert `pinned_content` row with `status = fetching`.
4. Call Filebase `pin-by-CID` with the CID and any provider hints. This is async on Filebase's side; we poll or receive webhook for completion.
5. On pin verified:
   - Update `pinned_content.status = pinned`, record `total_bytes`.
   - If `kind` has a known schema and content fetches as JSON under size cap, walk it: a. Fetch JSON content via our IPFS gateway (not Filebase pin API). b. Extract nested CIDs per schema (see Walker §). c. For each nested CID, check per-root byte budget. If budget permits, enqueue with `parent_cid` set and `depth+1`. d. Write `cid_children` rows for dedup cache.
6. On pin failure after retry budget exhausted:
   - Update `pinned_content.status = fetch_failed`, record error.
   - Emit metric; leave row for manual triage or later retry.

**Retry policy.** Exponential backoff, max 5 attempts, total time budget ~10 minutes. Fetch failures can be transient (DHT propagation delay), so retries are essential. Distinguish "not-yet-found" (retry) from "malformed-cid" (fail fast).

**Idempotency.** The combination of CID-based addressing and the "check-before-act" pattern at step 1 means workers are naturally idempotent. A message redelivered mid-pin just results in a no-op.

### Recursive URI walker

![Pasted image 20260422200232](./_attachments/Pasted%20image%2020260422200232.png)

Implemented as a library consumed by the pinning pipeline. Not a standalone service.

**Schema definitions** (initial set; extend as needed):

```python
# Pseudocode; real implementation in whatever Atlas runs.

SCHEMAS = {
    "metaevidence_v1": {
        "uri_fields": [
            "fileURI",                          # main attachment
            "evidenceDisplayInterfaceURI",      # display script
            "dynamicScriptURI",                 # dynamic script
        ],
        # Some fields are nested; walker traverses sub-objects.
        "nested_paths": ["rulingOptions"],     # if rulingOptions has reserved URI fields
    },
    "evidence_v1": {
        "uri_fields": ["fileURI"],
        "nested_paths": [],
    },
    "dispute_template_v2": {
        # V2 templates have a more structured schema. Walker should be
        # tolerant of new fields; unknown URI-looking values logged
        # but not auto-pinned.
        "uri_fields": ["policyURI", "attachment"],  # verify actual fields
        "nested_paths": [],
    },
    "curate_item_v2": {
        # Item data is typically a JSON with fields matching the list's
        # column schema. Many columns are URIs.
        "uri_fields": "shape_detect",  # per-list schema varies
    },
}
```

**Walker algorithm.**

```python
walk(root_cid, kind, byte_budget):
    queue = [(root_cid, kind, depth=0)]
    discovered_cids = set()
    bytes_so_far = 0
    
    while queue:
        cid, kind, depth = queue.pop()
        if cid in discovered_cids: continue
        discovered_cids.add(cid)
        
        if depth > MAX_DEPTH: continue
        if bytes_so_far > byte_budget: break
        
        # check dedup cache
        if cache.has(cid):
            nested = cache.get(cid)
            for n in nested: queue.append((n, infer_kind(n, kind), depth+1))
            continue
        
        content = fetch(cid)
        bytes_so_far += len(content)
        if len(content) > PER_CID_SIZE_CAP: 
            log("size cap hit", cid); continue
        
        schema = SCHEMAS.get(kind)
        if not schema: continue  # raw, no walk
        
        nested = extract_cids(content, schema)
        cache.set(cid, nested)
        
        for n in nested:
            queue.append((n, infer_child_kind(kind, field), depth+1))
```

**Shape-detection fallback.** For unknown `kind` or unrecognized content structure, optionally scan JSON for string values matching CID regex patterns. In INITIAL deployment, log these but do NOT auto-pin. Promote to auto-pin per-`kind` after reviewing logs and adding the schema explicitly.

**Dedup cache.** `cid_children(parent_cid, child_cid, field_path, discovered_at)`. On cache hit, reuse the child list — same metaevidence referenced by many disputes doesn't re-walk.

### GC worker

**Loop.** Every 5 minutes:

1. Query pending rows where `expires_at < now()`.
2. For each, batch-query the relevant subgraph for the CID. If any subgraph shows an on-chain reference, promote to confirmed.
3. For truly-expired rows, apply reference counting: decrement pending refcount on the CID. If pending refcount reaches zero AND CID is not in protocol pool:
   - Call Filebase unpin.
   - Delete pending rows.
   - Insert blacklist row for the CID.
4. Emit metrics: rows expired, rows promoted, unpin operations.

**Never unpin a CID that's in the protocol pool.** Protocol pool means on-chain referenced — durable forever.

**Reference counting for multi-requester case.** A single CID can be pre-registered from multiple IPs. Expire each row individually; only unpin when the last one expires. Implementation: `pending_rows` keyed by `(cid, requester_ip)`, not `cid` alone.

### CDN bandwidth policy layer

**Enforcement point.** Whichever layer serves `/ipfs/:cid` requests — Cloudflare Worker in front of Filebase, Nginx/Envoy, or custom service.

**Policy.**

- Lookup `pinned_content.pool` for the requested CID. Cache lookup result for 60s.
- If `pool = protocol`: generous bandwidth, normal CDN behavior.
- If `pool = pending`: apply tight per-CID rate limits. Default proposal (tune on data):
  - 500 KB/s per CID per client IP
  - 100 requests/day per CID total
- If `pool = null` (CID not in our pinned set): serve normally — might be someone else's IPFS content coming through our public gateway. Apply generic gateway rate limits if configured.

**Rationale.** Legitimate users of pending content are the submitter verifying their upload and maybe a preview. Jurors/curators show up after on-chain reference, at which point content is confirmed.

---

## Data model

PostgreSQL (or equivalent). Index column selection matters for query patterns noted in parentheses.

### `pinned_content`

```sql
CREATE TABLE pinned_content (
    cid              TEXT PRIMARY KEY,
    status           TEXT NOT NULL,      -- fetching, pinned, fetch_failed, unpinned
    pool             TEXT NOT NULL,      -- pending, protocol
    kind             TEXT,               -- metaevidence_v1, etc., null for unknown
    first_seen_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    confirmed_at     TIMESTAMPTZ,
    total_bytes      BIGINT,
    root_source_tx   TEXT,               -- for confirmed, the tx hash that triggered
    pending_refcount INTEGER NOT NULL DEFAULT 0,
    error            TEXT                -- last error on fetch_failed
);

CREATE INDEX idx_pinned_pool ON pinned_content(pool) WHERE pool IS NOT NULL;
CREATE INDEX idx_pinned_status ON pinned_content(status);
```

### `pending_registrations`

```sql
CREATE TABLE pending_registrations (
    id               BIGSERIAL PRIMARY KEY,
    cid              TEXT NOT NULL REFERENCES pinned_content(cid),
    requester_ip     INET NOT NULL,
    kind_hint        TEXT,
    providers_hint   JSONB,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at       TIMESTAMPTZ NOT NULL,
    UNIQUE (cid, requester_ip)     -- idempotent per-requester
);

CREATE INDEX idx_pending_expires ON pending_registrations(expires_at);
CREATE INDEX idx_pending_ip ON pending_registrations(requester_ip);
```

### `blacklist`

```sql
CREATE TABLE blacklist (
    cid              TEXT PRIMARY KEY,
    reason           TEXT NOT NULL,      -- 'ttl_expired', 'admin', 'abuse_detected'
    blacklisted_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at       TIMESTAMPTZ         -- NULL = permanent
);
```

### `cid_children`

```sql
CREATE TABLE cid_children (
    parent_cid       TEXT NOT NULL,
    child_cid        TEXT NOT NULL,
    field_path       TEXT,               -- "fileURI", "policyURI", etc.
    discovered_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (parent_cid, child_cid)
);

CREATE INDEX idx_children_parent ON cid_children(parent_cid);
CREATE INDEX idx_children_child ON cid_children(child_cid);
```

### `subgraph_cursors`

```sql
CREATE TABLE subgraph_cursors (
    source_name      TEXT NOT NULL,
    chain_id         INTEGER NOT NULL,
    cursor           TEXT NOT NULL,      -- block number or indexer cursor
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (source_name, chain_id)
);
```

### `rate_limit_counters` (optional — Redis may be preferred)

Rate limit state. Redis with sliding-window counters is the standard pattern; skip the SQL equivalent here.

---

## State machines

### Per-CID, per-requester state (pending pool)

![Pasted image 20260422202043](./_attachments/Pasted%20image%2020260422202043.png)

```
   [new request]
         │
         ▼
   ┌──────────┐   on-chain ref    ┌────────────┐
   │ pending  │──────────────────▶│ confirmed  │
   └──────────┘                   └────────────┘
         │                                ▲
         │ TTL hit                        │
         ▼                                │
   ┌──────────┐  GC subgraph recheck      │
   │ expiring │───────────────────────────┘
   └──────────┘
         │  subgraph confirms no reference
         ▼
   ┌──────────┐
   │ expired  │  (row deleted, blacklist inserted if last ref)
   └──────────┘
```

### Per-CID, pinning pipeline

```
   [enqueued]
         │
         ▼
   ┌──────────┐     Filebase pin    ┌────────────┐
   │ fetching │────────────────────▶│   pinned   │
   └──────────┘                     └────────────┘
         │                                │
         │  retries exhausted             │  walker discovers nested
         ▼                                │  CIDs, enqueues them
   ┌──────────────┐                       ▼
   │ fetch_failed │                  (more pipeline runs)
   └──────────────┘
```

---

## Flows

### Happy path — SDK client with pre-register

```
1. SDK uploads content to Pinata (or any IPFS provider). Gets CID.
2. SDK fires two things in parallel:
   - POST /pre-register {cid, kind: "metaevidence_v1"}
   - Send on-chain tx referencing CID
3. Atlas pre-register endpoint:
   - Validates CID, checks blacklist, checks quotas
   - Writes pending row, TTL 72h
   - Enqueues (cid, metaevidence_v1) to pinning pipeline
   - Responds 202 to SDK
4. Pinning worker picks up job:
   - Calls Filebase pin-by-CID
   - On pinned, fetches JSON content, walks schema
   - Finds fileURI → enqueues attachment CID
   - Finds dynamicScriptURI → enqueues script CID
   - All bounded by per-root byte budget
5. Meanwhile, on-chain tx lands. Subgraph indexes it within ~30s.
6. Reconciliation worker (next cycle) queries subgraph, sees the
   referenced CID, checks pinned_content. Already pinned — promotes
   pending row to confirmed, moves CID to protocol pool.
7. CDN tier now applies generous bandwidth to the CID.
```

Pin-verified typically within seconds of the pre-register call. Confirmed typically within a minute of tx inclusion.

### Happy path — third-party client without pre-register

```
1. Third-party tool uploads to Pinata, gets CID, sends on-chain tx.
   Does not call pre-register.
2. On-chain tx lands. Subgraph indexes within ~30s.
3. Reconciliation worker (next cycle) queries subgraph, sees CID.
4. pinned_content has no row for CID — pipeline enqueues with `kind`
   inferred from subgraph source (e.g. evidence_v1).
5. Filebase pin-by-CID fetches via DHT (Pinata announces to DHT, so
   this works).
6. Content pinned, walker runs if JSON.
7. Row created directly in protocol pool (bypasses pending).
```

Pin-verified typically within 1-2 minutes of tx inclusion. Acceptable for non-pre-registering clients.

### Failure mode — user deletes Pinata pin in race window

```
With pre-register:
1. User uploads to Pinata at t=0, gets CID.
2. SDK calls pre-register at t=0.1s.
3. Atlas fetches from DHT (Pinata is advertising the CID), pins at
   t=5-30s typically.
4. User deletes Pinata pin at t=10s.
5. Atlas already has content. Safe.

Without pre-register (bare third-party flow):
1. User uploads to Pinata at t=0, gets CID.
2. Sends on-chain tx at t=1s. Included at t=3s.
3. Subgraph indexes at t=33s.
4. Atlas reconciliation runs at t=60s, enqueues pin.
5. If user deleted pin at t=50s, and no one else fetched the content
   (so DHT has only Pinata's record, now gone): Atlas can't find it.
6. CID reference on-chain, but content unavailable. Same failure as
   if user submitted a bad CID in the first place.
```

This is the residual risk of the bare third-party flow. Acceptable because (a) users don't normally delete pins within seconds of creation, (b) pre-register exists and is strongly recommended, (c) a user who deletes their own evidence is making a statement that Kleros courts can rule against.

### Abuse mode — bandwidth-farming a pending CID

```
1. Attacker pre-registers a CID containing their content.
2. Distributes links like https://cdn.kleros.io/ipfs/QmXX...
3. First few hundred requests succeed; after that, CDN rate limiter
   kicks in (500 KB/s per CID per client IP, 100 req/day per CID).
4. Content never gets on-chain reference, stays pending.
5. TTL hits, GC unpins, CID goes on blacklist.
6. Attacker cannot re-pre-register the same CID. New content means
   new CID, but each new CID eats from their per-IP quota.
```

Structurally bounded. See §Abuse Model.

### Abuse mode — pinbomb via nested CIDs

```
1. Attacker constructs a metaevidence JSON that references 10 files,
   each referencing 10 more files, each 100MB.
2. Attacker pre-registers the root CID with kind=metaevidence_v1.
3. Walker fetches root (small, passes). Finds 10 children. Enqueues.
4. First level children fetched; each references more. By the time
   per-root byte budget (500MB default) is hit, walker aborts.
5. Budget-exceeded event logged. Partial tree pinned. Attack contained.
6. If root never gets on-chain reference, whole tree expires in TTL.
```

Note the ceiling is per-root byte budget × TTL × concurrent pending per IP. Tighten per-IP pending-bytes quota if this ceiling is too high.

---

## Abuse Model

Structured around what an attacker wants to accomplish and what prevents them.

### Attacker goal: free IPFS pinning

**Attack:** Pre-register arbitrary content, use Atlas as a free pin.

**Structural defenses:**
- Pending pool is bounded in size per-IP and globally.
- TTL expires content; blacklist prevents rolling.
- Only confirmed (on-chain-referenced) content is durable. Producing an on-chain reference costs gas, which is the natural rate limit.

**Residual risk:** An attacker willing to pay gas to reference garbage content on a Kleros contract can get durable pinning. Mitigation: per- arbitrable-contract rolling byte budget on reconciliation-sourced pins. If a given arbitrable address is producing abusive volumes of content references, throttle its pin budget. Document how to tune.

### Attacker goal: free CDN bandwidth

**Attack:** Pre-register content, serve it via Atlas's IPFS CDN.

**Structural defense:** Asymmetric bandwidth policy. Pending content gets tight per-CID and per-IP rate limits at the CDN layer. Only confirmed content gets generous bandwidth.

**Residual risk:** An attacker could register many small CIDs (each within the per-CID cap but collectively burning bandwidth). Mitigation: per-IP aggregate bandwidth cap on pending tier, not just per-CID.

### Attacker goal: storage exhaustion (pinbomb)

**Attack:** Register a CID that expands to huge size via nested references.

**Structural defense:** Per-CID size cap (default 50 MB) and per-root byte budget (default 500 MB) in the walker. Depth limit prevents infinite recursion.

**Residual risk:** Attacker can still pin up to (root byte budget × concurrent pending per IP) per IP. If this turns out to be too much headroom, tighten the per-IP pending-bytes quota.

### Attacker goal: evade blacklist via rolling CIDs

**Attack:** Let CID expire, re-pre-register with a bit more content appended (different CID), repeat.

**Structural defense:** Per-IP rate limits on pre-register calls and aggregate pending-bytes quotas per IP. Even unique CIDs can't be registered faster than the quotas allow.

**Residual risk:** Attackers using distributed IPs (botnet) can scale past per-IP limits. Mitigation: global pending pool size cap — if it fills up, new pre-registers from any IP are throttled. Alert on unusual global pending volume.

### Attacker goal: evidence-tampering (delete Pinata pin post-tx)

**Attack:** User submits evidence, waits, deletes Pinata pin before anyone fetches, claims "content was never there."

**Structural defense:** Pre-register (for well-behaved clients) pins before tx lands. Reconciliation (for third-party clients) pins within minutes of tx inclusion.

**Residual risk:** A user who controls both their client and their IPFS provider, uploads, submits tx, and deletes before Atlas can fetch (seconds to a few minutes), wins the race. Unusual scenario — most users can't act that fast and don't have a reason to. Kleros courts can rule against content that isn't retrievable at dispute time anyway.

### Attacker goal: impersonate Kleros activity

**Attack:** Deploy a fake arbitrable, reference huge files in `Evidence` events, get Atlas to pin them.

**Structural defense:** Reconciliation only queries trusted Kleros subgraphs. An impersonator arbitrable that doesn't create real disputes on the Kleros arbitrator doesn't show up in the arbitrator subgraph. An impersonator that does create real disputes pays Kleros arbitration fees.

**Residual risk:** Third-party arbitrables that pay legitimate arbitration fees can reference large content. Same as "gas cost is the rate limit" — arbitration fees are a much higher rate limit, ~$50-500 per dispute depending on chain and subcourt. Per-arbitrable byte budget as described above handles pathological cases.

### Non-goals for the abuse model

We do not try to prevent:
- Legal but objectionable content (handled by Kleros dispute process)
- CIDs that become unreachable before Atlas can pin them (user's problem)
- Attackers who can saturate the Kleros arbitrator with real disputes (that's a Kleros-core-protocol problem, not this system's)

---

## Operational concerns

### Monitoring

Required metrics:

- **Pre-register rate** per IP, globally. Alert on sudden spikes.
- **Pending pool size** (rows and bytes). Alert when approaching global cap.
- **Pin latency** distribution: pre-register → pin-verified, tx-inclusion → pin-verified.
- **Subgraph lag** per source. Alert if lag > 5 minutes for arbitrator, 10 minutes for others.
- **Reconciliation queue depth**. Alert if growing unboundedly.
- **GC expire rate** and **promote-on-expire rate**. High promote-on- expire suggests TTL too short or subgraph lag too high.
- **Walker budget-exceeded events**. Each one is worth manual review.
- **Filebase pin failure rate**. Alert on elevated.
- **Blacklist growth rate**.

Dashboards: one for pinning pipeline throughput, one for pending pool health, one for reconciliation lag per subgraph.

### Public status endpoint

`GET /v1/status`: returns global health. Used by downstream tools that want to gate behavior on "is Atlas currently up and pinning?"

```json
{
  "status": "healthy" | "degraded" | "unhealthy",
  "pinning_lag_p50_ms": 4200,
  "pinning_lag_p99_ms": 45000,
  "subgraphs": [
    {"name": "arbitrator_mainnet", "lag_seconds": 25, "healthy": true},
    ...
  ],
  "pending_pool_utilization": 0.34
}
```

### Chain coverage

Kleros products run on multiple chains. Confirm during implementation:
- Ethereum mainnet (V1 + V2 Court)
- Arbitrum One (V2 Court primary)
- Gnosis Chain (several products)
- Polygon
- Possibly others (check current deployment)

Each chain has its own subgraphs. Reconciliation worker must be configured per chain.

### Redundancy

- **Filebase:** primary pin provider. Consider a secondary pin provider (e.g. w3up, own cluster node) for content above a certain importance threshold — not all content, just confirmed-pool content. Out of scope for initial implementation; capture as future work.
- **Subgraph indexer:** hosted service is primary. If reliability is insufficient, run own indexer. Monitor incident history of TheGraph hosted service and self-host if SLA is insufficient.
- **Database:** standard Postgres HA. No unusual requirements.

### Backpressure

If pinning pipeline queue depth exceeds a threshold:
- Pre-register endpoint begins returning 503 Service Unavailable with Retry-After. Protects internal SLAs.
- Reconciliation worker slows its poll rate (doesn't drop; just gets further behind, which is recoverable).

### Observability of content graph

Given the recursive walker, operators should be able to answer: "what nested content was pinned under this root CID?" — useful for debugging, cost attribution, and abuse investigation. The `cid_children` table + a simple tree query handles this.

### Admin interface

Needed eventually:
- Blacklist management (add, remove, reason).
- Manual pin/unpin (for operator intervention).
- Quota adjustment per IP (for known-good clients that need higher limits; alternative to adding an authenticated tier).
- Content graph inspection.

Out of scope for initial implementation but design the schema to support it.

---

## Open questions for implementation

Things the design doesn't fully resolve. Engineer picking this up should decide and document.

1. **Filebase pin-by-CID exact API.** The reference integration should verify: async vs sync semantics, webhook vs poll, max CID size, timeout behavior, provider-hint support. Validate before starting.

2. **Exact subgraph query surface per product.** Each Kleros product's subgraph has its own schema. Reconciliation needs a query per source. Initial development should audit the active subgraphs (Mintlify `/reference/api/subgraph` docs or direct inspection) and enumerate URI-bearing entities.

3. **Per-chain arbitrator subgraph URLs.** Example given for mainnet- display. Need equivalents for Arbitrum, Gnosis, Polygon, etc.

4. **Rate limit numbers.** Proposed defaults are starting points. They should be tuned on observed traffic. Expose as environment/config.

5. **Authenticated tier (future).** If/when added, what does the signed attestation payload look like, and what quota uplift does it grant? Defer until measurement shows it's needed.

6. **Backup pin provider.** For confirmed-pool content, should Atlas mirror to a second provider? What threshold? Cost/reliability tradeoff.

7. **Content-type negotiation.** Walker assumes JSON for known Kleros schemas. What if MetaEvidence is served as something unexpected? Fail gracefully, don't assume.

8. **Notification on pin-verified.** Should pre-register callers get a webhook when their CID is verified, or must they poll? Polling is simpler; webhooks are nicer UX. Ship polling first.
