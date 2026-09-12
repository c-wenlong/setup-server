# Bootstrap plan — firefly-iii SG finance automation

_Shipped note (2026-09-12): Phase 1 (setup.sh, docker-compose.yml, SETUP.md, TROUBLESHOOT.md) shipped even though docs/verification-log.md still shows 0.1 and 0.3 as unanswered, which this plan says must be answered before Phase 1 starts._

**Audience:** the agent picking this up. Read
[COMPETITIVE-ANALYSIS.md](COMPETITIVE-ANALYSIS.md) first — it explains *why*
each decision below is what it is, and lists dead ends not to re-explore.

**Target state:** Firefly III on `kai-home-server`, tailnet-only, fed by six
per-institution pullers at three tiers of automation. Replaces the manual
"download PDFs → parse → update Notion" monthly loop.

**Explicit non-goal:** full automation of all six accounts. Four of the six have
no individual API path (see analysis §3). Anyone who "solves" this by
reverse-engineering a bank app has broken the plan, not completed it.

---

## Phase 0 — Verification gate 🚧 START HERE

**Do not write deployment code before this phase closes.** One finding decides
the shape of the whole system.

| # | Question | How to answer | If it fails |
|---|---|---|---|
| 0.1 | **Can Kai's *personal* (non-business) Wise profile mint an API token that reads balance statements?** | Ask Kai to check `Your Account > Integrations and Tools > API tokens` on wise.com. If a token can be created, call `GET /v1/profiles` then the balance-statement endpoint for an SG profile. | Phase 2 dies. Fall back to Wise's monthly CSV export (still better than PDF). Escalate to Kai before redesigning. |
| 0.2 | Which Tiger exchange licences (SGX/US/HK) are on the account? | Tiger developer portal, developer-info page | HK data needs `props_path` in client config; adjust Phase 3 |
| 0.3 | Does DBS currently push transaction-alert **emails** (not just SMS/push) to `chenwenlongofficial@gmail.com`, and what do they contain? | Search Gmail for recent DBS alerts; sample 10-20 and record the exact formats | Phase 4 changes from parsing to monthly-PDF-only; DBS drops to Tier 3 |
| 0.4 | Can an individual / sole proprietor onboard to Finverse to link only their own accounts? | **One email to Finverse sales.** Send and move on — do not block on the reply | Nothing — this is opportunistic. DBS stays on Tier 2 |

**Gate:** record every answer in `docs/verification-log.md` with the date and
evidence. Phase 1 may start once 0.1 and 0.3 are answered; 0.2 and 0.4 can run
in parallel.

⚠️ **0.1 is the linchpin.** Vendor docs say Singapore is exempt from the PSD2/SCA
block on balance statements, but they consistently phrase personal tokens as a
*business account* feature. That contradiction is unresolved. Resolve it before
building.

---

## Phase 1 — Deploy Firefly III

This directory now lives **inside `setup-server`** (Kai moved it there on
2026-09-11 — deployment and integration code share one service directory rather
than the two-repo split the first draft assumed). Follow
`~/dev/setup-server/AGENTS.md` — those conventions are non-negotiable, and they
govern everything here.
Start from `code-server/setup.sh` as the reference implementation.

**Ports (verified free against `DIRECTORY.md` on 2026-09-11 — re-check with
`ss -ltn` and `tailscale serve status` before claiming):**

| Component | Local | Tailnet HTTPS |
|---|---|---|
| Firefly III web | `8097` | `:8097` |
| Data Importer | `8099` | `:8099` |

Follows the jellyfin/beszel convention of HTTPS port == local port.

⚠️ **Do not use 8080 or 8098.** 8080 is code-server (Firefly's upstream default —
easy trap). 8098 appeared in the first draft of this plan and is **wrong**: it is
held by an ad-hoc `python3 echosrv.py` (pid 1781019, up 1+ day, not a managed
service, absent from `DIRECTORY.md`). Possibly debris — **ask Kai before
reclaiming**, do not kill it.

⚠️ **`DIRECTORY.md` lags reality.** Verified against live `ss -ltn` on the box
2026-09-11: adguard (`:3080`, `:53`) and home-assistant (`:8123`) are running but
not in the table. **Always confirm with `ss -ltn` + `tailscale serve status`
before claiming a port**, never with the doc alone.

⚠️ **Memory is the real constraint.** Measured on the box 2026-09-11:
**2.1 GB available of 7.7 GB, and 2.0 GB of swap already in use.** The box is
under memory pressure *before* adding Firefly III + another Postgres. Set
container memory limits, and treat "is there room?" as a live Phase 1 question.
If AdventureLog or Dawarich are also under consideration they compete for the
same headroom — sequence deployments, do not stack them.

**Required deliverables** (per setup-server's checklist):

- [ ] `firefly-iii/setup.sh` — idempotent, non-root, binds `127.0.0.1` only,
      publishes via `tailscale serve`, ends by printing URL + management commands
- [ ] `firefly-iii/SETUP.md` — architecture, security model, deps, step-by-step,
      ops commands
- [ ] `firefly-iii/TROUBLESHOOT.md` — layered triage, symptom-keyed, nuke-and-pave
- [ ] `firefly-iii/tests/run-tests.sh` — mocked suite (stubs for `docker`,
      `tailscale`, `sudo`, `systemctl`, `loginctl`, `curl`, `id`) **green before
      any real box run**, plus `--live`
- [ ] Row in `setup-server/README.md` and `setup-server/DIRECTORY.md`
- [ ] Monitor line in `setup-server/monitoring/seed_kuma.py`

**Stack decisions:**

- Containers: `fireflyiii/core` + Postgres + `fireflyiii/data-importer`. Pin
  image tags — no `:latest` on a system of record.
- State in `~/services/firefly-iii/` (bind mounts, importer configs). **Never in
  git** — that is the backup target.
- Secrets (`APP_KEY`, DB password, Firefly personal access token) generated into
  a gitignored `.env`, mirroring the immich/vaultwarden pattern.
- Box has 7.7 GB RAM with immich, jellyfin, seafile, forgejo et al already
  resident. **Check headroom before deploying** and set container memory limits.

**Currency setup — do not skip.** Enable SGD (default), USD, EUR, and any other
currency held in YouTrip/Wise/Revolut wallets. Configure a real exchange-rate
source. A silent 1:1 fallback is the specific failure mode that disqualified
Securo; do not reproduce it here.

---

## Phase 2 — Wise puller (Tier 1: full automation)

**Gated on 0.1.**

- Endpoint: balance statements. Formats available: JSON, CSV, PDF, XLSX,
  **CAMT.053**, MT940, QIF. Prefer **CAMT.053** → Data Importer (native format,
  no custom mapping).
- `Authorization: Bearer <token>`. Token in `.env`, never in code, never logged,
  never in a URL.
- **Max 469 days** between `intervalStart` and `intervalEnd` — chunk any backfill.
- Run daily via systemd user timer with an overlapping lookback window (e.g. last
  30 days) so nothing is missed; rely on Firefly's duplicate detection.
- Multi-currency: Wise holds several balances. Pull **per balance/currency** and
  map each to its own Firefly asset account.

**Done when:** a fresh Wise transaction appears in Firefly within 24h with no
human action, correctly currencied, not duplicated.

---

## Phase 3 — Tiger Brokers puller (Tier 1: full automation)

- `pip install tigeropen`. Register at `developer.tigerbrokers.com.sg`, accept the
  API authorization agreement.
- 🔑 **The private key is shown exactly once and Tiger does not store it.** It is
  gone on page refresh. Have Kai save it to the password manager (vaultwarden,
  already running on `:8222`) *before* navigating away. PKCS#8 format.
- Retail accounts: ignore the `secret_key` parameter — institutional only.
- `account` in config switches between live and paper — assert it is **live**.
- **Scope:** positions, orders, balances. This is a portfolio feed, not a
  transaction feed. Model as a Firefly asset account whose balance is
  periodically reconciled, plus real transactions for deposits/withdrawals and
  realised trades. Do not try to represent every unrealised price tick as a
  transaction — it will pollute the ledger.
- Consider whether Ghostfolio is the better home for holdings detail, with
  Firefly holding only the account-level value. **Decide and record the
  decision** in `docs/decisions.md`.

**Done when:** Tiger account value in Firefly III matches the app, and
deposits/withdrawals reconcile against the DBS side of the transfer.

---

## Phase 4 — DBS via transaction-alert email (Tier 2: near-real-time)

**Gated on 0.3.** This is where the highest-value effort goes — DBS is the
primary account and has no API.

- Source: DBS transaction alert emails in Gmail. Kai already has Gmail wired into
  the toolchain.
- Approach: matched-label search → parse → POST to Firefly III's REST API →
  label as processed. **Idempotency is critical** — key on the DBS transaction
  reference where present, never on message ID alone.
- Expect multiple alert templates (card spend, PayNow, transfers, GIRO). Build a
  parser per template with an explicit "unrecognised format" path that
  **notifies rather than silently drops**. Push to ntfy topic `alerts` — already
  running on `:3003`.
- **Reconcile monthly** against the DBS eStatement PDF. Alerts are a live feed,
  not an authoritative record; the statement is truth.

**Done when:** a card swipe appears in Firefly within the hour, and monthly
reconciliation against the eStatement shows zero drift.

---

## Phase 5 — Manual-export importers (Tier 3: monthly, ~15 min)

For **DBS PayLah!, YouTrip, Revolut** — plus DBS eStatement for reconciliation.

Build a `bin/import-statements.sh` that watches a Seafile drop folder (Seafile is
already running on `:8443`), so Kai can export from a phone and have it ingest
automatically.

Per-source notes:

- **YouTrip** — PDF, **31-day max range, per currency wallet**. The worst
  ergonomics of the six. Document the exact export click-path in
  `docs/monthly-runbook.md` so it is mechanical.
- **PayLah!** — in-app history is 60 days; monthly eStatements under
  `More → PayLah! eStatements`. Only generated for months with activity or a
  positive balance — **absent months are normal, not an error**.
- **Revolut** — CSV export available; the easiest of the three. Use CSV, never PDF.

**DBS PDF parsing traps** (these will bite — see analysis §6):

- "Balance brought forward" / "carried forward" rows repeat on **every page** →
  phantom transactions if unfiltered
- Credit/Debit columns in some formats, single signed Amount in others
- **Date formats vary within one document** — `30 Jun 2025` for the statement
  date, `15/03/2025` for transactions

Use `pdfplumber` with explicit rules. Write fixtures from real (redacted)
statements and test against them.

---

## Phase 6 — Cut over from Notion

- Backfill history. Decide how far — recommend **12 months**; more is
  diminishing returns against real parsing effort. Confirm with Kai.
- Rebuild the Notion views Kai actually uses as Firefly reports; identify
  anything Firefly cannot express **before** decommissioning anything.
- Keep Notion read-only in parallel for **one full month**, reconcile the two at
  month end, then stop updating it.
- **Do not delete the Notion databases.** Archive them.

---

## Repo layout (target)

```
firefly-iii/
├── README.md
├── AGENTS.md
├── COMPETITIVE-ANALYSIS.md
├── PLAN.md
├── .env.example              # every var documented; real .env gitignored
├── bin/
│   ├── pull-wise.py
│   ├── pull-tiger.py
│   ├── parse-dbs-alerts.py
│   └── import-statements.sh
├── lib/
│   ├── firefly.py            # shared Firefly III API client
│   └── parsers/              # one module per statement format
├── tests/
│   └── fixtures/             # redacted real statements — NEVER real account numbers
├── systemd/                  # user timer units
└── docs/
    ├── verification-log.md   # Phase 0 answers, dated, with evidence
    ├── decisions.md          # ADR-style; every deviation from this plan
    └── monthly-runbook.md    # the ~15-min manual loop
```

---

## Conventions

- Deployment code → `~/dev/setup-server/firefly-iii/` under that repo's
  `AGENTS.md`. Integration code → here. Runtime state → `~/services/firefly-iii/`.
- **No secrets in git.** Ever. Gitignored `.env`, vaultwarden for anything a human
  needs to retrieve.
- Every puller: idempotent, safe to re-run, structured logging, non-zero exit on
  failure, and an ntfy alert on the `alerts` topic when it breaks. A silently
  broken finance puller is worse than no puller.
- **Fixtures must be redacted.** No real account numbers, balances or names in
  git — this repo may end up on Forgejo (`:3000`) or GitHub.

## Open questions for Kai

1. Wise personal-vs-business token access (0.1) — **blocking Phase 2**
2. How far back to backfill? (recommend 12 months)
3. Ghostfolio for holdings detail, or Firefly-only? (Phase 3)
4. Is Revolut SG retail or is there a Business account? (would change the §3
   finding — Business has a self-serve API)
5. RAM headroom on the box for another Postgres — check before Phase 1

## Definition of done

- [ ] Firefly III reachable at `https://kai-home-server.taild6a23f.ts.net:8097`,
      loopback-bound, Kuma-monitored, in `DIRECTORY.md`
- [ ] Wise + Tiger import with zero human action
- [ ] DBS transactions appear within the hour, reconciling to the eStatement
- [ ] Monthly manual loop documented and ≤15 minutes
- [ ] One full month reconciled against Notion before cutover
- [ ] Mocked tests green; `--live` green on the box
- [ ] Backups cover `~/services/firefly-iii/`
