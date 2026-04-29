# Atlas Pin-on-Reference, aka Pinion

Durability pinning for Kleros protocol content, regardless of where clients uploaded it.

![Pasted image 20260422200548](./_attachments/Pasted%20image%2020260422200548.png)

## What this is

Clients building on Kleros — frontends, SDKs, CLI tools, MCP servers, agent skills — need to reference content on IPFS (evidence, metaevidence, curate items, dispute templates, attachments). Historically the recommended path was to upload through Atlas's SIWE-authenticated endpoint, which pins to Filebase-backed Kleros infrastructure. This bundles two separate concerns — _upload_ and _durability_ — into a single authenticated service, which creates problems:

- **Friction for non-browser clients.** Origin validation and SIWE flows are awkward for CLIs, MCP servers, and agents. x402-based agentic uploads (e.g. Pinata) become second-class.
- **Abuse surface.** A free authenticated upload endpoint invites not-Kleros-related IPFS pinning and requires ongoing fair-use policing.
- **Single provider coupling.** Clients who prefer their own IPFS stack (their own node, Pinata, w3up) can't use it without losing durability guarantees.

This project reverses the default: **let clients upload wherever they want, and pin defensively on the Atlas side whenever content is referenced in a Kleros protocol interaction.** The durability guarantee is tied to on-chain consecration, not to who performed the upload.

## How it works, briefly

Three moving parts:

1. **Pre-register endpoint** — open, unauthenticated. Clients about to submit a tx call this with the CID they're about to reference. Atlas starts fetching and pinning immediately. Closes the race window between "Pinata has it" and "Atlas has it" to near zero.

2. **Subgraph reconciliation worker** — periodically queries Kleros subgraphs (arbitrator, curate, template registry, per-arbitrable evidence feeds) for CIDs that have been referenced on-chain and aren't yet in our pinned set. Pins anything missing. Self-heals across downtime, covers third-party clients that didn't pre-register.

3. **Recursive URI walker** — shared by both. When a pinned CID is JSON with a known Kleros schema (metaevidence, evidence, dispute template), walks the document for nested IPFS references and pins those too, bounded by depth and size limits.

Pre-registered content that never gets referenced on-chain is garbage-collected after a TTL and blacklisted from re-pinning.

## File map

| File                                                 | Purpose                                                                                           |
| ---------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| `README.md`                                          | This file. Orientation, glossary, key invariants.                                                 |
| [`CONTEXT.md`](./CONTEXT.md)                         | How this design came to be. Who was involved, what prompted it, what was considered and rejected. |
| [`DECISIONS.md`](./DECISIONS.md)                     | Decision log with rationales. Read this before modifying the design.                              |
| [`ARCHITECTURE.md`](./ARCHITECTURE.md)               | Full design: components, data model, flows, abuse model, operations.                              |
| [`IMPLEMENTATION_PLAN.md`](./IMPLEMENTATION_PLAN.md) | Phased build order with exit criteria per phase.                                                  |

If you're picking up this project fresh, read in order: README → CONTEXT → DECISIONS → ARCHITECTURE → IMPLEMENTATION_PLAN. CONTEXT and DECISIONS come before ARCHITECTURE deliberately — the shape of the system is load-bearing on a few non-obvious tradeoffs, and the design won't make sense without the rationales.

## Kleros context glossary

For engineers unfamiliar with the Kleros product landscape:

- **Atlas** — Kleros's IPFS backend team / service. Runs Filebase-backed pinning and IPFS CDN. Owns this project.
- **Filebase** — third-party S3-compatible IPFS provider used by Atlas as the underlying pin layer. Exposes a pin-by-CID API.
- **Kleros Court / V2 arbitrator** — the core decentralized arbitration contract. Emits `DisputeCreation` events that reference arbitrable contracts and `templateId`s.
- **Arbitrable contracts** — any contract that creates disputes on Kleros. Can be deployed by Kleros itself (Curate, Escrow, etc.) or by third parties. Emit `Evidence` events; V1 variants also emit `MetaEvidence`.
- **Curate** — Kleros's token-curated registry product. A Curate factory deploys individual Curate list contracts dynamically.
- **DisputeTemplateRegistry** — V2 registry where arbitrable contracts register dispute templates (JSON schema on IPFS) with a `templateId`. Replaces V1's inline `MetaEvidence` event.
- **Evidence** — file/document/JSON a party submits during a dispute. References IPFS content; V1 format wraps in a JSON envelope with a `fileURI` to the actual attachment.
- **MetaEvidence** (V1 only) — JSON describing a dispute's context, linking to the arbitration policy URI, display interface URI, ruling options, etc.
- **SIWE** — Sign-In With Ethereum, an authentication standard. Used by the existing Atlas upload endpoint; intentionally NOT used by this project's pre-register endpoint.
- **x402** — HTTP-native agentic payment standard. Pinata exposes x402 endpoints so agents can pay per upload in USDC without accounts. We want to stay compatible with this UX, which is part of why pre-register is open and unauthenticated.

## Key invariants

These hold across all components. If you're about to change code that violates one of them, stop and check DECISIONS.md first.

1. **Pre-register is open.** No SIWE, no origin validation, no wallet signature required. Abuse is controlled structurally via GC, quotas, blacklists, and asymmetric bandwidth policy — not by auth.

2. **On-chain reference is the durability commitment.** Content that has been referenced on-chain in a whitelisted Kleros protocol interaction gets pinned durably. Content that hasn't is transient and subject to GC.

3. **CIDs are content-addressed and immutable.** Deduplication and idempotency are free. Retries are safe. Cache aggressively.

4. **Subgraph is the source of truth for on-chain state.** Do not maintain parallel indexes of `disputeID → arbitrable`, `templateId → templateUri`, factory deployments, etc. Query the relevant subgraph.

5. **Nested URI walking is bounded.** Depth limit, per-CID size limit, per-root byte budget. A malicious or malformed document must not be able to exhaust storage.

6. **Expired pending CIDs are blacklisted.** Once a CID's pre-registration expires without on-chain confirmation, it cannot be pre-registered again. Prevents rolling-window abuse.

7. **Check on-chain before unpinning.** GC always re-checks subgraph immediately before unpinning an expired CID. Protects against a legitimate tx landing seconds before the TTL.

## Non-goals

- Atlas is **not** a general-purpose IPFS pinning service. Content unrelated to Kleros protocol interactions should not be pinned by this system.
- We do **not** guarantee pre-registered CIDs are served at high bandwidth before on-chain confirmation. Pending content gets tight per-CID bandwidth caps; only confirmed content gets the generous CDN tier.
- We do **not** replace or deprecate the existing SIWE-authenticated upload endpoint. Frontend apps may continue using it as a convenience. This project is additive.
- We do **not** attempt to detect or block clients that upload to third-party providers without pre-registering. Subgraph reconciliation catches their content after tx inclusion; that's sufficient.

## Status

Design complete. Implementation not started. See IMPLEMENTATION_PLAN.md for phased build order.
