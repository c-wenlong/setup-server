# Verification log

Phase 0 answers. Every entry needs a **date** and **evidence** (a quoted doc
line, an API response, a screenshot path). "I think so" is not an answer.

Nothing verified yet — all four questions are open as of 2026-09-11.

---

## 0.1 — Can Kai's *personal* Wise profile mint a token that reads balance statements? 🚧 BLOCKING

**Status:** OPEN
**Blocks:** Phase 2 (Wise puller)

**The contradiction to resolve:** Wise docs state balance statements are
retrievable via personal token for accounts based in US/CA/AU/NZ/**SG**/MY
(SG-registered profiles are exempt from the SCA challenge a static token cannot
answer) — but the same docs frame personal tokens throughout as a *business
account* feature.

**How to test:** `Your Account > Integrations and Tools > API tokens` on
wise.com → create token → `GET /v1/profiles` → balance-statement endpoint for the
SG profile.

**Answer:**
**Date:**
**Evidence:**

---

## 0.2 — Which Tiger exchange licences (SGX/US/HK) are on the account?

**Status:** OPEN
**Affects:** Phase 3 — HK market data needs `props_path` in the client config

**Answer:**
**Date:**
**Evidence:**

---

## 0.3 — Does DBS push transaction-alert *emails*, and what do they contain?

**Status:** OPEN
**Blocks:** Phase 4 (DBS near-real-time). If emails don't exist or are
content-free, DBS drops to Tier 3 monthly-PDF-only.

**How to test:** search Gmail (`chenwenlongofficial@gmail.com`) for recent DBS
alerts; sample 10–20 and record **each distinct template** — card spend, PayNow,
transfers, GIRO. Note whether amount, merchant, date and a transaction reference
are present. The reference matters most: it is the idempotency key.

**Answer:**
**Date:**
**Templates found:**

---

## 0.4 — Can an individual / sole proprietor onboard to Finverse?

**Status:** OPEN — **non-blocking, opportunistic**
**Affects:** could move DBS from Tier 2 to Tier 1

Send one email to Finverse sales and move on. Ask specifically about linking
*only one's own* accounts as an individual, and what KYB is required. Pricing is
~$0.50 per connected account with a free trial and no contract; SG individual
coverage includes DBS, OCBC, UOB, Citibank.

**Answer:**
**Date:**
**Evidence:**
