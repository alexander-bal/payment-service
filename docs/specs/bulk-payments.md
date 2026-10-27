# Bulk Payments

## Overview

Firms on the platform hold a balance in US cents and settle debts with each other through it. A bulk payment lets one firm — the payer — pay any number of other firms — the payees — in a single request. The service accepts the request only if the payer's balance covers every payment in it. On acceptance it records the bulk payment and each payment in it, debits the payer by the total, and credits each payee, all as one change. Otherwise it denies the whole request and nothing changes. Every request carries an idempotency key, so a client can always retry without paying twice. The service runs as multiple load-balanced instances over one PostgreSQL database, so every guarantee here holds under concurrent requests arriving at any instance.

## Goals and Non-Goals

### Goals

- Define the firm, bulk payment, and payment entities and the money invariants the service keeps between them
- Define the bulk payment endpoint: request contract, validation, and the success response
- Define the all-or-nothing settlement rule and the funds check that decides it
- Define how concurrent requests across instances stay correct and deadlock-free
- Define mandatory idempotency keys, so a client that loses a response can always retry without paying twice
- Define the input limits and the error vocabulary

### Non-Goals

- Authentication and authorization — performed upstream before a request reaches this service (CON-5)
- Firm management — creating, renaming, or deleting firms, and depositing to or withdrawing from balances; firms are seeded
- Reading bulk payments or payments back — listing, history, statements, or lookups. The `bulk_payments` table is shaped to support a later UI listing, but this feature exposes no read surface
- Reversals, refunds, partial acceptance, and scheduled or recurring payments
- Currencies other than USD, and fees
- Rate limiting

## Functional Requirements

### FR-1: Firms

- A firm SHALL carry an internal integer `id`, a `name`, a `balance_cents` in US cents, and a `uuid`, which is the public identifier used in requests.
- `uuid` SHALL be unique across firms.
- A firm's `balance_cents` SHALL stay between 0 and 2,147,483,647 inclusive at all times (CON-1).
- Firms SHALL be created out of band (seed data). This feature exposes no surface that creates or alters a firm, apart from the balance changes of settlement (FR-6).

### FR-2: Bulk Payments and Payments

- A bulk payment SHALL record one accepted request: `payer_firm_id` (foreign key to firms), `idempotency_key`, `request_fingerprint` (FR-8), `total_amount_cents`, and a system-assigned `created_at`.
- A payment SHALL record one transfer: `bulk_payment_id` (foreign key to bulk payments), `payer_firm_id` and `payee_firm_id` (both foreign keys to firms), `amount_cents`, and `description`.
- An accepted request SHALL produce exactly one bulk payment, plus exactly one payment row per entry, all belonging to that bulk payment. Entries to the same payee SHALL NOT be merged.
- Within a bulk payment, payment ids SHALL ascend in request order, so the stored rows reproduce the request's entry order.
- Bulk payments and payments SHALL be immutable once created.

### FR-3: Bulk Payment Submission

- The system SHALL accept bulk payments via `POST /bulk_payments` with a JSON body.
- The body SHALL carry `payer_firm_uuid` and a `payments` array. Each entry SHALL carry `amount`, `payee_firm_uuid`, and `description`.
- The request SHALL carry an `Idempotency-Key` header (FR-8).
- Fields beyond these SHALL be ignored.

### FR-4: Request Validation

- The system SHALL validate the request shape before reading or locking any firm. It SHALL reject the request with HTTP 400 when:
  - the `Idempotency-Key` header is missing, or is not 1 to 255 printable ASCII characters;
  - the body is not a JSON object, or a required field is missing or has the wrong JSON type;
  - `payer_firm_uuid` or any `payee_firm_uuid` is not a well-formed UUID. UUIDs are matched case-insensitively;
  - `payments` is empty or holds more than 1,000 entries;
  - any `amount` is not a JSON string matching `^\d+(\.\d{1,2})?$`, i.e. whole dollars with at most two decimal places. JSON numbers, signs, exponents, thousands separators, and surrounding whitespace do not match;
  - any amount, or the request total, falls outside 1 to 2,147,483,647 cents ($0.01 to $21,474,836.47) inclusive (CON-1);
  - any `description` is blank, longer than 255 characters, contains a NUL character, or is not valid UTF-8;
  - any `payee_firm_uuid` equals `payer_firm_uuid`.
- A 400 response SHALL report every offending entry by its index in `payments`, not only the first.

### FR-5: Firm Resolution

- An unknown `payer_firm_uuid` SHALL be rejected with HTTP 404.
- If any `payee_firm_uuid` matches no firm, the whole request SHALL be denied with HTTP 422, listing every unknown uuid.
- The same payee MAY appear in several entries.

### FR-6: Funds Check and Settlement

- Each amount SHALL convert to exactly its value in integer cents (`"5800.5"` is 580,050 cents). The request total SHALL be the sum of those amounts.
- The whole request SHALL be denied with HTTP 422 when:
  - the payer's balance is below the total, or
  - crediting any payee by the sum of its entries would push that payee's balance above the upper bound of FR-1.
- Otherwise the system SHALL, in a single database transaction, insert the bulk payment and every payment, debit the payer by exactly the total, and credit each payee by exactly the sum of its entries. The sum of all firm balances SHALL NOT change. The system SHALL then respond with HTTP 201.
- Settlement SHALL be all-or-nothing. A denied or failed request leaves no bulk payment, no payment rows, and no balance change.
- The funds and limit checks SHALL use balances read under the row locks of NFR-1.

### FR-7: Responses

- A 201 response SHALL carry the bulk payment's `id`, `payer_firm_uuid`, `total_amount`, and `payments`. `payments` holds one element per created payment, in request order, each with `id`, `payee_firm_uuid`, `amount`, and `description`.
- Amounts in responses SHALL be strings in dollars with exactly two decimal places: a request amount of `"300"` is returned as `"300.00"`.
- Every error response SHALL carry an `error` object with a machine-readable `code`, a human-readable `message`, and, where useful, `details` (offending indices, unknown uuids, the required total). The codes are listed under Error Scenarios.

### FR-8: Idempotent Retries

- Every request SHALL carry an `Idempotency-Key` header. A request without a valid key SHALL be rejected with HTTP 400 before any firm is read (FR-4).
- An accepted request's key and request fingerprint SHALL be stored on its bulk payment (FR-2), scoped to the payer. Both are written in the settlement transaction, so a key exists only if its payments committed.
- A key SHALL stay in effect for as long as its bulk payment exists. Bulk payments are never deleted.
- The fingerprint SHALL be computed over the normalized request: the payer, plus each entry in order as payee uuid, amount in cents, and description. Formatting differences such as whitespace, field order, uuid letter case, or `"300"` versus `"300.00"` SHALL NOT change it.
- A later request from the same payer with the same key and the same fingerprint SHALL NOT settle again. It SHALL return HTTP 201 with an `Idempotent-Replayed: true` header, regardless of current balances. The response body SHALL be rebuilt from the stored bulk payment and its payments, and SHALL match the original response.
- The same key with a different fingerprint SHALL be rejected with HTTP 409.
- Only accepted requests SHALL create a bulk payment. A retry after a 400, 404, 422, or 503 response SHALL be evaluated afresh.

## Non-Functional Requirements

### NFR-1: Concurrency

- Correctness SHALL rest on the database alone, so any number of instances can serve requests (CON-3). No instance SHALL rely on in-process locks, caches, or balances read outside the settlement transaction.
- Before the funds check, the settlement transaction SHALL lock the payer row and every distinct payee row with `SELECT … FOR UPDATE`, acquiring the locks in ascending `id` order. The funds and limit checks of FR-6 SHALL use the balances read under those locks.
- Requests whose sets of firms overlap SHALL therefore run one after another, and requests with disjoint sets SHALL run in parallel.
- Because every request acquires its locks in the same order, deadlocks between bulk requests SHALL be impossible, including a request from A to B racing one from B to A.
- The idempotency key lookup (FR-8) SHALL happen while the payer row lock is held, so two in-flight requests with the same key cannot both settle. A unique index on `bulk_payments (payer_firm_id, idempotency_key)` SHALL back this up.
- A request that cannot acquire its whole set of row locks within 5 seconds in total SHALL fail with HTTP 503 and leave no partial state.

### NFR-2: Data Integrity

- No reader, on any instance, SHALL ever see some of a request's payments or balance changes without the rest.
- Money SHALL be handled as integer cents throughout. Amounts SHALL be converted from their string form without passing through floating point, so rounding cannot create or lose a cent.
- The database SHALL enforce the lower balance bound of FR-1 with a check constraint, as a backstop to the funds check of FR-6.

## Constraints (Externally Imposed)

- **CON-1 — Brief schema.** The `firms` and `payments` tables use exactly the columns and types given in the challenge brief: `INTEGER` for ids, foreign keys, and cents, and `TEXT` for names, uuids, and descriptions. The 32-bit `INTEGER` ceiling is the source of the balance bounds and the amount range (FR-1, FR-4). The brief's seed `INSERT` runs unmodified. Indexes, foreign keys, `NOT NULL`, and check constraints may be added. This feature makes exactly two schema additions of its own: the `bulk_payments` table and the `payments.bulk_payment_id` column. (FR-1, FR-2, FR-8)
- **CON-2 — Mandated status codes.** The brief fixes 201 for an accepted request and 422 for a request denied for insufficient funds. The other status codes in this spec are this feature's own choices. (FR-6)
- **CON-3 — Deployment.** The service runs as multiple load-balanced instances over one PostgreSQL database at its default `READ COMMITTED` isolation level. (NFR-1)
- **CON-4 — USD only.** All money is in US dollars, stored as integer cents. (FR-1, FR-6)
- **CON-5 — Upstream authentication and authorization.** Every request reaches this service through an upstream layer, such as an API gateway or a calling service. That layer has already authenticated the caller and checked that it may pay from `payer_firm_uuid`. The service does no authentication or authorization of its own and trusts `payer_firm_uuid` as given. (FR-3, FR-5)

## Error Scenarios

Rejections are decided in this order: 400, then 404, then the idempotency outcome (409 or replay), then 422. The first one that applies decides the response.

| Scenario | Response |
|---|---|
| `Idempotency-Key` header missing or malformed (FR-4) | HTTP 400 — `invalid_request` |
| Body is not valid JSON or not an object, or a required field is missing or mistyped | HTTP 400 — `invalid_request` |
| Malformed UUID, empty or oversized `payments`, bad amount or description, payee equal to payer, or total above the maximum | HTTP 400 — `invalid_request`, with the offending indices |
| `payer_firm_uuid` matches no firm | HTTP 404 — `payer_not_found` |
| `Idempotency-Key` reused by the same payer for a different request | HTTP 409 — `idempotency_key_reused` |
| `Idempotency-Key` and request identical to an already accepted one | HTTP 201 — the original response, rebuilt from the stored bulk payment, with `Idempotent-Replayed: true`; nothing is settled again |
| Any `payee_firm_uuid` matches no firm | HTTP 422 — `payee_not_found`, listing the unknown uuids |
| Payer's balance is below the request total | HTTP 422 — `insufficient_funds`, with the required total |
| A payee's balance would exceed the maximum | HTTP 422 — `payee_balance_limit_exceeded`, listing the affected payees |
| Row locks not acquired within the wait bound | HTTP 503 — `busy`; safe to retry |
| Unexpected failure | HTTP 500 — internal server error; no partial state |

## Acceptance Criteria

### AC-1: Brief Sample Request

**Given** the database is seeded with the brief's three firms:

```sql
INSERT INTO firms (id, name, balance_cents, uuid)
VALUES (1, 'Pinecrest CPA Group', 5000000, '3f1c9a2e-7b4d-4c1e-9a55-2d8e6f0b7c41'),
       (2, 'Lopez Bookkeeping', 50000, '8b2e4c71-0d3a-4f6e-b1c9-5a7d2e9f4c10'),
       (3, 'Nair Tax Services', 200000, 'e5f18b3c-2a9d-4c07-8e6b-1d4a7f9c3b25');
```

**When** Pinecrest submits the brief's sample request. The brief's version has no `Idempotency-Key` header, so one is added (FR-8):

```http
POST /bulk_payments
Content-Type: application/json
Idempotency-Key: brief-sample-1

{
  "payer_firm_uuid": "3f1c9a2e-7b4d-4c1e-9a55-2d8e6f0b7c41",
  "payments": [
    {
      "amount": "6250",
      "payee_firm_uuid": "e5f18b3c-2a9d-4c07-8e6b-1d4a7f9c3b25",
      "description": "Overflow returns, August 2026"
    },
    {
      "amount": "5800.5",
      "payee_firm_uuid": "e5f18b3c-2a9d-4c07-8e6b-1d4a7f9c3b25",
      "description": "Amended returns, August 2026"
    },
    {
      "amount": "1200.75",
      "payee_firm_uuid": "8b2e4c71-0d3a-4f6e-b1c9-5a7d2e9f4c10",
      "description": "Bookkeeping cleanup, 3 clients"
    }
  ]
}
```

**Then:**

- The response is HTTP 201, with `total_amount` `"13251.25"` and three `payments` in request order, with amounts `"6250.00"`, `"5800.50"`, and `"1200.75"` (FR-7).
- The firm balances are:

  | Firm | Balance before | Balance after |
  |---|---|---|
  | Pinecrest CPA Group | $50,000.00 | $36,748.75 |
  | Lopez Bookkeeping | $500.00 | $1,700.75 |
  | Nair Tax Services | $2,000.00 | $14,050.50 |

- One bulk payment exists for Pinecrest with `total_amount_cents` of 1,325,125, and three payment rows belong to it, with ids ascending in request order. The two entries to Nair are stored as two separate payments (FR-2).
- The three balances sum to $52,500.00 both before and after (FR-6).

## Security Considerations

- The service trusts `payer_firm_uuid` because authentication and authorization happen upstream (CON-5). A request that bypassed that layer could spend from any firm whose uuid it knows, so the service SHALL NOT be reachable except through the upstream.
- `insufficient_funds` details SHALL carry the required total but never the payer's balance, so a denial discloses no balance even if the upstream check is misconfigured (FR-7).
- Money SHALL never pass through floating point, so rounding cannot create or destroy cents (NFR-2).
- Because every request must carry an idempotency key, a client that retries after a timeout or a dropped connection can never settle the same request twice (FR-8).
- Idempotency keys SHALL be scoped per payer. Two firms that choose the same key never collide, and a replay only ever returns a bulk payment that belongs to the same payer (FR-8).
- The batch size and lock-wait bounds SHALL keep a single request from locking a large share of firms or holding locks indefinitely (FR-4, NFR-1).
- Input SHALL be validated at the boundary before any firm is read or locked, so malformed values never reach a transaction (FR-4).
