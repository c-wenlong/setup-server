# Competitive analysis — self-hosted finance tracking for a Singapore individual

Research date: **2026-09-11**. Everything below has a source link. Anything
marked ⚠️ UNVERIFIED is a claim from vendor docs or search results that has not
been confirmed against a live account — treat those as assumptions, not facts.

The trigger for this research was [Securo](https://www.usesecuro.com/en), an
open-source self-hosted money manager, and the goal of replacing a manual
"download bank PDFs → parse → update Notion databases monthly" workflow with
something API-driven.

---

## 1. The headline finding

**The app is not the bottleneck. Singapore bank data access is.**

Every self-hosted finance app in this category — Securo, Actual Budget, Firefly
III — gets bank data from the same small set of third-party aggregators:
Pluggy (Brazil), Enable Banking (EU/PSD2), GoCardless (EU), SimpleFIN
(US/Canada), Akahu (NZ), Spectre.

**None of them cover Singapore retail banks.** Switching apps therefore changes
where the PDFs land, not whether you download them. The differentiator has to be
something else — and it is: whether the app can run imports *unattended*.

---

## 2. App comparison

### Securo (the app that prompted this)

- AGPL-3.0, FastAPI + React + Postgres, Docker Compose, self-hosted.
  [Repo](https://github.com/securo-finance/securo) ·
  [Docs](https://docs.usesecuro.com/docs)
- Genuine features: multi-currency, rules-based auto-categorisation, budgets,
  recurring transactions, TOTP 2FA, OIDC (Authentik/Pocket ID), multi-user
  workspaces, optional self-hosted LLM/RAG agents.
- Sync providers: **Pluggy (BR), Enable Banking (EU), SimpleFIN (US)**.
- File import: OFX, QIF, CSV, CAMT.

**Why not chosen:** No SG coverage, so its whole sync advantage evaporates. On
top of that it is a young, solo-founder, openly AI-assisted project with little
independent review — acceptable for a toy, not for the system of record on
personal finances. Its multi-currency handling also silently falls back to a 1:1
rate without an Open Exchange Rates key, which for a six-currency SG/global
setup is a correctness landmine.

**Not a bad project — just the wrong bet for this jurisdiction and this role.**

### The field

| Tool | Licence | Model | Sync | Unattended import? |
|---|---|---|---|---|
| **Firefly III** ✅ | AGPL-3.0 | Double-entry ledger, strong rules engine, multi-currency | GoCardless, Enable Banking, Spectre, SimpleFIN, CSV/CAMT — via a **separate Data Importer container** | **Yes — cron-triggered** |
| Actual Budget | MIT | YNAB-style envelope budgeting, fast UI, offline-capable | Akahu, Enable Banking, GoCardless, SimpleFIN, Pluggy | **No** — [docs](https://actualbudget.org/docs/advanced/bank-sync/) state sync is a manual button click |
| Securo | AGPL-3.0 | Expense manager | Pluggy, Enable Banking, SimpleFIN | Unclear, immature |
| Ghostfolio | AGPL-3.0 | Portfolio / net worth only | — | Complementary, not a replacement |
| Maybe | — | — | — | **Reportedly no longer developed** — exclude |

### Why Firefly III wins here

1. **The Data Importer runs on cron.** This is the deciding factor. Since every
   SG account needs a custom puller anyway, the app's job is to be a good
   *sink* with a scriptable ingest path. Firefly III is the only one of the
   three that ingests without a human clicking a button.
2. **Double-entry.** Every transaction has a source and a destination. With six
   accounts across multiple currencies and constant inter-account transfers
   (DBS → YouTrip top-up, DBS → Tiger funding, Wise → DBS), envelope budgeting
   would double-count transfers as spending. Double-entry models them correctly.
3. **Rules engine + REST API.** Auto-categorisation on import, and a documented
   API so pullers can POST transactions directly instead of round-tripping
   through files where that is cleaner.
4. **Maturity.** ~24k GitHub stars, actively maintained, large user base — this
   holds financial records, so boring and well-trodden beats novel.

**Cost of the choice:** heavier than Actual (PHP/Laravel + Postgres), and the
UI is utilitarian. Accepted deliberately.

### ⚠️ Stale advice to ignore

**GoCardless Bank Account Data** (formerly Nordigen) appears in most tutorials
as the free EU aggregator. It is now marked *"not accepting new accounts"* in
Actual's docs, and reportedly requires a paid business account — the free
personal tier is gone. Irrelevant for SG anyway, but do not burn time on it.

---

## 3. Per-institution API access — the six accounts

**Score: 2 of 6 reachable by an individual.**

| # | Institution | Individual API? | Finding |
|---|---|---|---|
| 1 | DBS | ❌ | [DBS Developers](https://www.dbs.com/dbsdevelopers/discover/index.html) hosts 160+ APIs but is **partner-gated** — commercial onboarding, vetted partners only. Singapore has no PSD2-style mandate, so access is contractual, not a right. |
| 2 | DBS PayLah! | ❌ | Merchant/partner payment APIs only. In-app history capped at **60 days**; older data needs monthly eStatement PDFs. |
| 3 | YouTrip | ❌ | No public or partner API. [Statements](https://www.you.co/sg/blog/youtrip-transaction-statements/) are PDF only, **max 31-day range, per currency wallet** → 12+ exports per wallet per year. Worst of the six. |
| 4 | Revolut | ❌ | [Open Banking API](https://developer.revolut.com/docs/guides/build-banking-apps/introduction-to-the-open-banking-api/who-can-access-the-api) requires a valid **eIDAS or OBIE certificate** as a regulated UK/EEA TPP, routed via Revolut Ltd (UK). SG retail accounts are out of scope; SG docs cover Open Banking only as a *Business* integration. |
| 5 | **Wise** | ✅ | See below — the key finding. |
| 6 | **Tiger Brokers** | ✅ | [TigerOpen](https://developer.tigerbrokers.com.sg/?lang=en_US) is explicitly open to retail individuals and free. |

### Wise — the key finding ⚠️ VERIFY FIRST

Personal API tokens normally **cannot** retrieve balance statements — PSD2
Strong Customer Authentication blocks it, and a static token cannot answer an
SCA challenge. But there is a six-country carve-out.

> Funding transfers and retrieving balance statements via API are not supported
> except for accounts based in the US, Canada, Australia, New Zealand,
> **Singapore**, and Malaysia.
> — [Wise personal tokens docs](https://docs.wise.com/api-docs/features/authentication-access/personal-tokens)

The mechanism: the [Balance Statements
endpoint](https://docs.wise.com/api-reference/balance-statement) is SCA-protected,
but SCA applies to profiles registered *outside* US/AU/NZ/SG/CA/MY. An
SG-registered profile is exempt from the challenge the token cannot satisfy.

Output formats: **JSON, CSV, PDF, XLSX, CAMT.053, MT940, QIF**. CAMT.053 and QIF
import directly into Firefly III. Max window between `intervalStart` and
`intervalEnd` is **469 days**.

**⚠️ The unresolved risk:** Wise's docs consistently frame personal API tokens
as a *business account* feature ("automate your own Wise business account"), and
phrase the six-country carve-out in terms of business accounts. Whether a
**consumer/personal profile** can mint a token with statement access is
**unconfirmed**. This single question decides whether Phase 1 exists.
Token creation path: `Your Account > Integrations and Tools > API tokens`.

### Tiger Brokers — confirmed retail-open

- Requirements: funded live TigerTrade account, register as developer at
  `developer.tigerbrokers.com.sg`, accept the API authorization agreement.
- **Free** — no fees for API access or for orders placed via the API.
- Python SDK: `pip install tigeropen`
  ([repo](https://github.com/tigerfintech/openapi-python-sdk)). Covers market
  data, trading, account management, WebSocket push.
- ⚠️ **The private key is displayed exactly once and Tiger does not store it.**
  It vanishes on page refresh. Save it before doing anything else; use
  "Regenerate" if lost. PKCS#8 format recommended for the Python SDK.
- Retail accounts ignore the `secret_key` config parameter — that is
  institutional-only.
- Check which exchange licences (SGX/US/HK) are attached to the account; HK
  market data requires a token path via `props_path` in the client config.
- **Scope caveat:** this is holdings, orders and positions — a portfolio feed,
  not a bank transaction feed. It answers "what do I own", not "what did I
  spend".

---

## 4. SGFinDex — the obvious idea, and why it fails

[SGFinDex](https://www.mas.gov.sg/development/fintech/sgfindex) is the MAS +
GovTech national financial data rail, built on Singpass, covering 15 FIs
(including DBS/POSB) plus CPF, HDB and IRAS. It sounds like exactly the right
answer. It is not, for two independent reasons — **either one is fatal**:

1. **Closed to non-financial-institutions.** The consuming apps are bank- or
   government-run (DBS digiWealth, MyMoneySense, UOB TMRW, HSBC FinConnect).
   Planner Bee — a licensed FA firm, far better positioned than an individual —
   *had* DBS sync via SGFinDex and was told at short notice that the function is
   [not approved for use by non-financial institutions](https://plannerbee.co/learn-personal-finance/update-on-syncing-dbs-to-planner-bee/).
   The [API spec](https://specs.api.sgfindex.gov.sg/) confirms approval-gated
   onboarding: prior approval, an onboarding process per API resource, then
   credential exchange. No published individual-developer path.
2. **It is not transaction data.** Bank and insurer data reflects the
   **previous month-end / last statement balance**. CPF and HDB are
   current-as-of-refresh. It is a net-worth snapshot rail, not a spending feed.

**Do not spend time here.** If a future agent is tempted, re-read this section.

**Market context:** Seedly [discontinued its app](https://seedly.sg/posts/important-update-seedly-app-discontinuation/)
on 2025-12-31 and deleted expense data after 2026-03-31. SG consumer aggregation
is contracting, not expanding. Do not build on a consumer aggregator's continued
existence.

---

## 5. The aggregator escape hatch — Finverse

The one commercial route that could unlock DBS.

- [Finverse](https://www.finverse.com/bank-data-api) — HK-based, APAC-focused,
  consent-based OAuth (**not** screen scraping).
- SG coverage includes **DBS, OCBC, UOB and Citibank for individual accounts**
  (HSBC and Standard Chartered are business-only).
- Pricing: **~$0.50 per connected account**, pay for active users only, no setup
  fee, free trial with no contract.
- Sandbox `api.sandbox.finverse.net` → production `api.prod.finverse.net`.

**⚠️ The blocker:** production onboarding routes through sales — their config
placeholders literally read `contact_finverse_support`. Expect KYB. Whether a
sole proprietor or individual can onboard to link *only their own* accounts is
**unknown and worth exactly one email to ask**. Do not build against it before
that answer arrives.

Brankas and Finantier are the regional alternatives but are Indonesia/Philippines
-focused and weaker in SG.

---

## 6. Design consequences

What the research forces:

1. **Custom pullers per institution.** No off-the-shelf provider covers this
   set. The app must be a scriptable sink → Firefly III.
2. **Three tiers of automation, by necessity:**
   - **Full** — Wise, Tiger (API)
   - **Near-real-time** — DBS (transaction-alert email parsing; Gmail is already
     wired into Kai's toolchain, and DBS pushes alerts for card spend and
     transfers — reconcile monthly against the eStatement)
   - **Monthly manual export** — PayLah!, YouTrip, Revolut
3. **Currency correctness is not optional.** Six accounts, many currencies.
   Firefly III's multi-currency support must be configured properly — never
   allow a silent 1:1 fallback (the specific trap Securo has).
4. **Budget for DBS PDF parsing quirks** where PDFs are unavoidable:
   - "Balance brought forward" / "carried forward" rows repeat on **every page**
     and become phantom transactions if not filtered.
   - Some formats use separate Credit/Debit columns, others a single signed
     Amount column.
   - **Date formats vary within the same document** (e.g. `30 Jun 2025` for the
     statement date vs `15/03/2025` for transactions).

## 7. Explicitly rejected

| Option | Why not |
|---|---|
| Securo | No SG coverage; immature for a system of record; 1:1 FX fallback |
| Actual Budget | No unattended sync — the one thing that matters here |
| Maybe | Unmaintained |
| SGFinDex | Closed to non-FIs **and** month-end balances only |
| GoCardless | Free personal tier gone; EU-only regardless |
| `ttwj/ReLah` (reverse-engineered PayLah! client) | Last confirmed working **2019**; cert pinning and device binding have almost certainly killed it; breaches DBS terms. **Do not use or revive.** |
| Reverse-engineering YouTrip's mobile endpoints | Same reasoning — MAS-licensed entity, real account-closure risk |
| Staying on Notion | Viable, but the manual PDF loop is the actual complaint |
