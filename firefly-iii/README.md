# firefly-iii — Singapore finance automation

Replaces the manual "download PDFs → parse → update Notion" loop with a
self-hosted [Firefly III](https://www.firefly-iii.org/) ledger on
`kai-home-server`, fed by per-institution pullers.

**Not a fork of Firefly III.** This is the service directory: the deploy
(`setup.sh`, compose, tests) plus the integration layer around it — the pullers,
the transforms, and these docs. It lives inside `setup-server` as one
self-contained service directory, per that repo's convention, so
`~/dev/setup-server/AGENTS.md` applies to everything here.

## Start here

| Doc | What it is |
|---|---|
| [COMPETITIVE-ANALYSIS.md](COMPETITIVE-ANALYSIS.md) | Why Firefly III over Securo/Actual, and the per-institution API access findings that shaped the design. Read this before questioning any decision in the plan. |
| [PLAN.md](PLAN.md) | The bootstrap plan. Phased, with a spike gate up front. This is the executable document. |
| [AGENTS.md](AGENTS.md) | Conventions for working in this repo. |

## The one-paragraph version

Six accounts to track: DBS, DBS PayLah!, YouTrip, Revolut, Wise, Tiger Brokers.
Research (Sept 2026) found that exactly **two** expose an API an individual can
get on their own — Wise (personal API token; Singapore is one of six
jurisdictions exempt from the PSD2/SCA block on balance statements) and Tiger
Brokers (TigerOpen, explicitly retail-open and free). The other four have no
individual path: DBS and PayLah! are partner-gated, YouTrip has no API at all,
Revolut's Open Banking API is fenced behind UK/EEA regulated-TPP certificates,
and SGFinDex — the obvious national rail — is closed to non-financial
institutions and returns month-end balances rather than transactions anyway.

So the target is **not** full automation. It is: 2 accounts fully automated,
DBS near-real-time via transaction-alert email parsing, and 3 accounts on a
~15-minute monthly statement import. That is still a large improvement on the
current process, and the ledger becomes queryable.

## Status

Nothing built yet. `PLAN.md` Phase 0 is the next action, and it is a
**verification gate** — one Wise API finding needs confirming before the
architecture is committed to.
