# Context

How this design came to be, for future reference.

The final decisions recorded in DECISIONS.md should be treated as the current best understanding, not as contract. Engineers implementing this should feel free to raise concerns and revisit — with the constraint that reopening a decision needs to grapple with the rationale in DECISIONS.md, not just the conclusion.

## What prompted the design work

Two threads of agentic experimentation over the preceding months motivated the work:

**Unsuccessful experiment: agents using API endpoints not intended for external use.** Early agentic experiments found that agents, given access to "upload to IPFS" tasks, tended to discover and use whatever endpoints were reachable — notably including TheGraph's IPFS endpoint. That endpoint exposes a minimal pinning-looking API but does NOT provide durable pinning; content gets garbage-collected on TheGraph's schedule, independent of anything Kleros cares about. An agent submitting evidence via that path would produce a CID referenced on-chain that becomes unretrievable within days. The failure mode is silent and downstream — jurors see missing evidence, no one knows why. This surfaced the concrete cost of leaving the upload path underspecified.

**Successful experiment: agents using third-party IPFS providers like Pinata.** Agents using Pinata (including x402-based pay-per-call flows) produced durable uploads that worked end-to-end for Kleros interactions. This validated that third-party IPFS providers are a reasonable path for agent UX specifically, and raised the question of how to integrate them cleanly with Kleros durability guarantees — leading to the pin-on-reference architecture in this design.

Together these two observations meant:

- Agents WILL find and use whatever IPFS-upload-shaped thing is reachable, correctness unknown, unless we give them something better.
- Good third-party providers exist and work well with agent UX. We don't need to build our own upload layer; we need to solve the durability-ownership question.
- SIWE-gated upload to Atlas cleanly serves browsers but is the wrong shape for agents, who then go find something else — often something worse.

The pin-on-reference design is a direct response: decouple upload (let clients use Pinata, x402, or anything else that works for them) from durability (Atlas pins what gets referenced on-chain, regardless of where it came from).

## Why the design has several reversals

The design went through a few pivots worth naming because the final shape looks simple but the reasoning wasn't.

1. **SIWE-required → SIWE-optional-then-unused.** Initial instinct was to keep SIWE on the pre-register endpoint for rate limiting. Recognized that SIWE's value in browser contexts (paired with origin validation against CSRF) doesn't transfer to CLI/MCP/bot contexts, and its cost defeats the exact agent UX we're trying to preserve.

2. **Event watcher primary → subgraph primary.** Initial design had a WebSocket event watcher as the main post-tx discovery mechanism, chosen specifically to minimize race-window latency. Once the pre-register endpoint (which absorbs the latency requirement entirely) was part of the design, the remaining role of post-tx discovery shifted from "beat the race" to "catch stragglers," at which point subgraph polling's 30-60s lag became acceptable. Subgraphs already solve the hard discovery problem (factory deployments, third-party arbitrables, template registry indexing) for free, so the watcher's marginal value dropped sharply.

3. **Contract whitelist → no contract whitelist.** Followed directly from the subgraph pivot. Kleros subgraphs already track every factory-deployed contract and every third-party arbitrable that creates real disputes. Duplicating that discovery inside the watcher was reinventing work.

These reversals are preserved in DECISIONS.md because a fresh implementer would otherwise "rediscover" the rejected options and waste time on them.

## Who was involved

- **Jay Buidl** — Lead Developer, Kleros. Design ownership.
- **Fortunato** — PM, Curate. Joined the Atlas-team call; represents product perspective for Curate use cases which are among the largest-volume IPFS consumers in Kleros.
- **Atlas team** — operates the Filebase-backed pinning infrastructure this project builds on top of. Their feasibility input shaped the constraints (Filebase capabilities, existing SIWE endpoint conventions, operational tooling).
- **Claude** — design partner for the 2026-04-22 synthesis session, drafted this documentation.

## Things that were discussed but didn't make it into the design

For completeness, so future sessions don't propose them as "new":

- **Atlas as a general-purpose IPFS pinning service.** Considered and rejected — creates perpetual abuse-policing overhead for not-Kleros-related content.

- **Mandatory migration of existing frontends off the SIWE upload endpoint.** Rejected — no forcing function, migration can happen on frontend teams' own schedules. The existing endpoint remains available.

- **Captcha on the pre-register endpoint.** Rejected — defeats the agent UX that motivates the whole design.

- **Per-Kleros-address rate limiting (instead of per-IP).** Rejected as default because it reintroduces auth friction. Kept available as the future authenticated tier (Phase 5) for callers who want higher quotas.

- **Running our own IPFS cluster in addition to Filebase.** Deferred to Phase 6, contingent on incident evidence.

## How to update these documents

If implementation reveals that a decision was wrong, or operational experience motivates a change:

1. Update DECISIONS.md with a new record (D13, D14, ...) rather than editing the existing records. The history of reasoning matters. Mark superseded decisions as `Status: Superseded by D<N>`.
2. Update ARCHITECTURE.md to reflect the new state.
3. If the change affects phasing, update IMPLEMENTATION_PLAN.md.
4. Append a note to this CONTEXT.md summarizing the change and why.

Avoid editing this document's origin section — it's a snapshot, not a living summary.

## Appended context

_(This section is for future additions. As the project evolves, append dated entries here to capture the "why" of major changes.)_
