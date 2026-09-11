# Decisions

ADR-style log. Every deviation from [PLAN.md](../PLAN.md) gets an entry, or a
future agent reading the plan will "correct" it back.

Format: **Context** (what forced the choice) → **Decision** → **Consequences**
(including what it costs) → **Date**.

---

## 001 — Firefly III over Securo and Actual Budget

**Context.** Evaluating self-hosted finance apps to replace a manual
Notion + PDF workflow for six SG/global accounts. Full analysis in
[COMPETITIVE-ANALYSIS.md](../COMPETITIVE-ANALYSIS.md).

**Decision.** Firefly III.

**Reasons.**
1. No aggregator covers Singapore retail banks, so every account needs a custom
   puller regardless of app. The app's job is to be a good scriptable *sink*.
2. Firefly's Data Importer runs on **cron**; Actual's sync is a manual button
   click. Unattended import is the deciding capability.
3. Double-entry correctly models constant inter-account transfers (DBS →
   YouTrip top-up, DBS → Tiger funding, Wise → DBS) that envelope budgeting
   would double-count as spending.
4. Mature and widely used — this becomes the system of record for personal
   finances.

**Consequences.** Heavier stack than Actual (PHP/Laravel + Postgres) on a
7.7 GB box already running immich, jellyfin, seafile and forgejo. Utilitarian
UI. Both accepted.

**Rejected:** Securo (no SG coverage, immature, silent 1:1 FX fallback), Actual
(no unattended sync), Maybe (unmaintained).

**Date:** 2026-09-11

---

## 002 — Three tiers of automation, not full automation

**Context.** Only 2 of 6 institutions expose an API an individual can obtain:
Wise and Tiger Brokers. DBS and PayLah! are partner-gated, YouTrip has no API,
Revolut requires UK/EEA regulated-TPP certificates. SGFinDex is closed to
non-financial institutions *and* returns month-end balances rather than
transactions.

**Decision.** Accept a mixed model — Tier 1 API (Wise, Tiger), Tier 2 email-alert
parsing (DBS), Tier 3 monthly manual export (PayLah!, YouTrip, Revolut).

**Consequences.** ~15 minutes of manual work per month remains, permanently,
absent a change in SG open-banking policy or Finverse individual onboarding.
This is a genuine improvement on the current process, not a workaround to be
"fixed" later by circumventing a bank's terms.

**Date:** 2026-09-11
