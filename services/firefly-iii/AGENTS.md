# Agent instructions — firefly-iii

Integration layer around a self-hosted Firefly III instance on
`kai-home-server`: per-institution pullers that feed a double-entry ledger for
six Singapore/global accounts.

**This is not a fork of Firefly III.** It is one `setup-server` service
directory holding both the deploy and the pullers. The root
`~/dev/setup-server/AGENTS.md` governs — the rules below are *additional*
constraints specific to handling financial data, not replacements.

## Read before doing anything

1. [PLAN.md](PLAN.md) — phased plan. **Phase 0 is a verification gate.**
2. [COMPETITIVE-ANALYSIS.md](COMPETITIVE-ANALYSIS.md) — why every decision is
   what it is, and the dead ends already ruled out.

If you are about to conclude "we should just use SGFinDex" or "let's try
Actual Budget instead" — both are already investigated and rejected with
reasons. Re-read §4 and §2.

## Non-negotiable conventions

- **This holds financial records.** Boring and correct beats clever. Pin image
  tags, no `:latest`, no unreviewed dependencies.
- **No secrets in git.** Gitignored `.env` only; anything a human retrieves goes
  in vaultwarden (`:8222`). Never log a token, never put one in a URL.
- **Redact all fixtures.** No real account numbers, balances or names in
  `tests/fixtures/` — this repo may land on Forgejo or GitHub.
- **Every puller is idempotent.** Safe to re-run, overlapping lookback windows,
  duplicate detection keyed on a bank-provided reference where one exists.
- **Fail loudly.** Non-zero exit plus an ntfy push to topic `alerts` (`:3003`)
  on any failure or unrecognised statement format. A silently broken finance
  puller is worse than no puller — it produces confident wrong numbers.
- **Currency correctness.** Multi-currency across all six accounts. Never allow
  a 1:1 FX fallback; that flaw is precisely why Securo was rejected.
- **Statements are truth, alerts are a feed.** Email/alert-derived transactions
  must reconcile against the monthly statement. Never treat an alert as
  authoritative.

## Boundaries

- **Never** reverse-engineer a bank or e-wallet mobile app. DBS, PayLah! and
  YouTrip have no individual API — that is the finding, not an obstacle to route
  around. `ttwj/ReLah` exists; do not revive it. These are MAS-licensed entities
  and the risk is account closure.
- Do not add password auth as a substitute for the tailnet boundary.
- Do not bind anything to `0.0.0.0`.

## Recording decisions

Any deviation from PLAN.md goes in `docs/decisions.md` (ADR-style: context,
decision, consequences, date). Phase 0 answers go in `docs/verification-log.md`
with evidence and a date. Future agents rely on these — an undocumented
deviation will get "corrected" back by someone reading the plan.

## Escalate to Kai, don't guess

- Anything requiring a login, an OAuth approval, or a one-time code
- Any spend commitment (e.g. Finverse onboarding)
- Phase 0 question 0.1 failing (kills Phase 2 as designed)

For auth links and one-time codes, deliver via Telegram per the global
instructions — do not just print to a terminal Kai may not be watching.
