# Payment Service

Rails API for bulk payments between firms. `POST /bulk_payments` moves money from one payer firm to many payees, all
or nothing. The full contract is in [docs/specs/bulk-payments.md](docs/specs/bulk-payments.md).

## Problems and approach

### Main challenges

1. **Atomicity.** A bulk payment settles completely or not at all.
2. **Concurrency.** Several app instances share one database. Concurrent requests must not overspend a balance or lose
   each other's updates.
3. **Deadlocks.** Requests that lock the same firms in different orders (A pays B while B pays A, or a cycle of three
   firms) must not deadlock.
4. **Idempotency.** A client that retries after a timeout must never pay twice.

### Approach

- **Stack.** Rails and RSpec on PostgreSQL. PostgreSQL runs in Docker Compose, the app in Compose or natively.
- **Synchronous settlement.** Each request settles in one database transaction, with no message queue or Redis. The
  brief requires the result in the response (201 or 422), and the database already gives the guarantees needed.
- **Locking.** One `SELECT … ORDER BY id FOR UPDATE` locks the payer and all payees in id order. Every request locks in
  the same order, so requests cannot deadlock. Lock waits are capped with `SET LOCAL statement_timeout`; a request that
  hits the cap gets `503 busy` and can retry.
- **Business logic.** Validation, firm lookups and the first idempotency check run before the transaction. Under the
  locks, the transaction checks the payer's funds and that no payee balance would exceed the `INTEGER` maximum.
- **Efficient SQL.** The number of statements does not grow with batch size: one `UPDATE … CASE` changes all
  balances, and one multi-row `INSERT` adds all payments.
- **Idempotency.** Each accepted request is stored in a `bulk_payments` row with a unique
  `(payer_firm_id, idempotency_key)` index. The key is checked before the transaction and again under the payer's
  lock, so two parallel requests with the same key settle once. A stored request fingerprint lets a retry get the
  original response, while reusing a key for a different request returns `409`. The brief did not ask for this table,
  but money transfers need idempotency, and the table also links each payment to its batch.
- **Database constraints.** Check constraints and foreign keys (non-negative balances, positive amounts, payee ≠
  payer, payments tied to their batch's payer) catch bugs that get past the application code.
- **Testing.** Specs run against real PostgreSQL. In the concurrency spec, each request has its own thread and
  connection. A barrier connection holds the locks until all requests are blocked behind it, which forces the
  interleavings that would deadlock or double-spend if locking were wrong. Specs also check invariants, such as the
  total of all balances never changing.

## Assumptions

- **Authentication is upstream.** A gateway or calling service has already checked that the caller may pay from
  `payer_firm_uuid`. This service trusts it, so it must be reachable only through that layer.
- **The brief's schema is kept.** For simplicity, the `firms` and `payments` columns keep the brief's names and types,
  including `INTEGER` cents, and the brief's seed runs unchanged. I only added the `bulk_payments` table,
  `payments.bulk_payment_id`, indexes and constraints.
- **Limits follow from the schema.** Balances, amounts and totals stay within $0.01–$21,474,836.47 (the `INTEGER`
  maximum in cents). A credit that would push a payee past it fails the request with
  `422 payee_balance_limit_exceeded`.
- **Batch size is 1–1,000 payments.** This bounds how many rows a transaction locks and for how long.
- **`Idempotency-Key` is required.** The brief's sample has none, but without it a client cannot safely retry. A
  missing key returns `400`.
- **Amounts are strict strings** matching `^\d+(\.\d{1,2})?$`, converted to cents without floating point. JSON
  numbers, signs, exponents and thousands separators are rejected. All money is USD.
- **A firm cannot pay itself** (`400`).
- **Entries to the same payee stay separate** payment rows, in request order. Only the balance update sums them.
- **Status codes other than 201 and 422 are my choice:** `400` malformed request, `404` unknown payer, `409` key reused
  for a different request, `503` lock timeout. An unknown payee returns `422`, like insufficient funds: the request is
  valid but cannot be settled.
- **Out of scope:** firm management (firms are seeded), reading payments back, refunds, other currencies, fees and
  rate limiting.

## Prerequisites

- Docker with Compose v2 (`docker compose version`)
- For the native setup only: Ruby 4.0.9, installed with any version manager (mise, rbenv, asdf, chruby; the repo has
  both `.ruby-version` and `mise.toml`)

PostgreSQL always runs in Docker (`compose.yml`) on `127.0.0.1:54331`.

## Run with Docker (recommended)

```sh
docker compose --profile app up --build
```

This starts PostgreSQL and the app in development mode on <http://localhost:3000>. The first start creates and
migrates the development and test databases and seeds three firms. The source is bind-mounted, so code changes reload
without a restart. Keep `--build` so `Gemfile.lock` changes get installed.

Open the [admin console](#try-it-in-the-admin-console-recommended) at <http://localhost:3000/admin/>, or check it
from another terminal:

```sh
curl -i localhost:3000/up    # HTTP/1.1 200 OK
```

Stop with `Ctrl-C` or `docker compose --profile app down` (add `-v` to delete the database volume). Run Rails commands
in the container with `docker compose --profile app exec app <command>`, e.g.
`docker compose --profile app exec app bin/rails console`.

## Run natively

```sh
docker compose up -d --wait db   # PostgreSQL only
bundle install
bin/rails db:prepare             # creates, migrates and seeds the development and test databases
bin/rails server                 # http://localhost:3000
```

Both setups use port 3000, so run one at a time.

## Run the tests

Tests use real PostgreSQL, including a concurrency spec that forces lock contention across connections.

```sh
# Docker
docker compose --profile app run --rm app bundle exec rspec

# Native (needs `docker compose up -d --wait db`)
bundle exec rspec
```

`bin/ci` runs the full CI locally: setup, RuboCop, bundler-audit, Brakeman and RSpec.

## Git hooks

A pre-commit hook runs `bin/ci` against the staged changes. Install it once after `bundle install`:

```sh
bundle exec lefthook install
```

Skip it for one commit with `LEFTHOOK=0 git commit ...`.

## Try it in the admin console (recommended)

A bonus beyond the brief: a small admin page for checking the service in a browser instead of with curl. It is plain
HTML, CSS and JavaScript in [public/admin/](public/admin/), served by Rails from the same origin. It needs no build
step and no CORS setup, and has no authentication.

Start the app with either setup, then open <http://localhost:3000/admin/>. It has four tabs:

- **Firms**, **Payments** and **Bulk payments** list every row with a few key columns, newest first, with no
  pagination.
- **Test requests** shows two fixed requests, read-only, each with a Send button and the response status, the
  `Idempotent-Replayed` header and the body:
  - **Sample bulk payment.** The [AC-1](docs/specs/bulk-payments.md#ac-1-brief-sample-request) request, with a new
    `admin-sample-<uuid>` key on each page load. The first send returns `201`, and later sends replay the same
    response without moving money. Reloading the page and sending again creates another bulk payment. Pinecrest's
    $50,000 seed balance covers three, and the fourth returns `422`.
  - **Insufficient balance.** Lopez Bookkeeping pays $5,000.00, more than it can ever hold here. It always returns
    `422 insufficient_funds`.

To check AC-1:

1. Reset the firms to the brief's seed balances. This deletes all bulk payments. For the native setup, drop the
   `docker compose --profile app exec app` prefix:

   ```sh
   docker compose --profile app exec app bin/rails db:seed:replant
   ```

2. On **Firms**, the balances are $50,000.00 / $500.00 / $2,000.00.
3. On **Test requests**, send the sample bulk payment. It returns `201 Created`.
4. Send it again. It returns the same body with `Idempotent-Replayed: true`.
5. On **Firms**, the balances are now $36,748.75 / $1,700.75 / $14,050.50. The total is $52,500.00 before and after.
   **Payments** shows the three payments, and **Bulk payments** shows one batch.
6. Send the insufficient balance request. It returns `422` with `insufficient_funds`, and the balances don't change.

The page reads from three JSON endpoints added for it. They are unauthenticated, like the rest of the service:

| Endpoint             | Returns, newest first unless noted                                                      |
| -------------------- | --------------------------------------------------------------------------------------- |
| `GET /firms`         | `id`, `uuid`, `name`, `balance`, ordered by id                                         |
| `GET /payments`      | `id`, `bulk_payment_id`, `payer_name`, `payee_name`, `amount`, `description`           |
| `GET /bulk_payments` | `id`, `payer_name`, `total_amount`, `payments_count`, `idempotency_key`, `created_at` |

## Verify with curl (optional)

The same checks from the terminal, plus error cases the admin console doesn't cover.

### Acceptance case (AC-1)

This replays [AC-1](docs/specs/bulk-payments.md#ac-1-brief-sample-request) against a running app. The commands are
for Docker; for the native setup, drop the `docker compose --profile app exec app` prefix.

1. Reset the firms to the brief's seed balances. This deletes all bulk payments:

   ```sh
   docker compose --profile app exec app bin/rails db:seed:replant
   ```

2. Send the brief's sample request:

   ```sh
   curl -i -X POST localhost:3000/bulk_payments \
     -H 'Content-Type: application/json' \
     -H 'Idempotency-Key: brief-sample-1' \
     -d '{
       "payer_firm_uuid": "3f1c9a2e-7b4d-4c1e-9a55-2d8e6f0b7c41",
       "payments": [
         {"amount": "6250", "payee_firm_uuid": "e5f18b3c-2a9d-4c07-8e6b-1d4a7f9c3b25", "description": "Overflow returns, August 2026"},
         {"amount": "5800.5", "payee_firm_uuid": "e5f18b3c-2a9d-4c07-8e6b-1d4a7f9c3b25", "description": "Amended returns, August 2026"},
         {"amount": "1200.75", "payee_firm_uuid": "8b2e4c71-0d3a-4f6e-b1c9-5a7d2e9f4c10", "description": "Bookkeeping cleanup, 3 clients"}
       ]
     }'
   ```

   Expected: `HTTP/1.1 201 Created` with this body. The ids are 1, 1, 2, 3 only on a fresh database, because a replant
   does not reset id sequences:

   ```json
   {"id":1,"payer_firm_uuid":"3f1c9a2e-7b4d-4c1e-9a55-2d8e6f0b7c41","total_amount":"13251.25","payments":[
     {"id":1,"payee_firm_uuid":"e5f18b3c-2a9d-4c07-8e6b-1d4a7f9c3b25","amount":"6250.00","description":"Overflow returns, August 2026"},
     {"id":2,"payee_firm_uuid":"e5f18b3c-2a9d-4c07-8e6b-1d4a7f9c3b25","amount":"5800.50","description":"Amended returns, August 2026"},
     {"id":3,"payee_firm_uuid":"8b2e4c71-0d3a-4f6e-b1c9-5a7d2e9f4c10","amount":"1200.75","description":"Bookkeeping cleanup, 3 clients"}]}
   ```

3. Check the balances:

   ```sh
   docker compose --profile app exec app bin/rails runner \
     'Firm.order(:id).each { |f| puts format("%-20s %d.%02d", f.name, *f.balance_cents.divmod(100)) }'
   ```

   Expected (before: 50000.00 / 500.00 / 2000.00; the total is 52500.00 before and after):

   ```
   Pinecrest CPA Group  36748.75
   Lopez Bookkeeping    1700.75
   Nair Tax Services    14050.50
   ```

4. Send the same curl again. It returns the same 201 body with an `idempotent-replayed: true` header, and the balances
   don't change.

### Error examples

Every error body is `{"error": {"code", "message", "details"?}}`. Several codes share an HTTP status, so clients should
branch on `error.code`. A failed request stores nothing, so you can repeat these in any order with the same key.

**404 `payer_not_found`**: unknown payer firm.

```sh
curl -i -X POST localhost:3000/bulk_payments \
  -H 'Content-Type: application/json' -H 'Idempotency-Key: demo-404' \
  -d '{"payer_firm_uuid": "00000000-0000-4000-8000-000000000000",
       "payments": [{"amount": "100", "payee_firm_uuid": "8b2e4c71-0d3a-4f6e-b1c9-5a7d2e9f4c10", "description": "Unknown payer"}]}'
```

```json
{"error":{"code":"payer_not_found","message":"The payer firm does not exist."}}
```

**422 `payee_not_found`**: one or more unknown payee firms. Nothing settles, including the valid entries.

```sh
curl -i -X POST localhost:3000/bulk_payments \
  -H 'Content-Type: application/json' -H 'Idempotency-Key: demo-422-payee' \
  -d '{"payer_firm_uuid": "3f1c9a2e-7b4d-4c1e-9a55-2d8e6f0b7c41",
       "payments": [{"amount": "100", "payee_firm_uuid": "8b2e4c71-0d3a-4f6e-b1c9-5a7d2e9f4c10", "description": "Known payee"},
                    {"amount": "100", "payee_firm_uuid": "00000000-0000-4000-8000-000000000000", "description": "Unknown payee"}]}'
```

```json
{"error":{"code":"payee_not_found","message":"Some payee firms do not exist.","details":{"unknown_payee_firm_uuids":["00000000-0000-4000-8000-000000000000"]}}}
```

**422 `insufficient_funds`**: Lopez Bookkeeping ($500.00, or $1,700.75 after AC-1) tries to pay $5,000. The details
include the required total, never the payer's balance.

```sh
curl -i -X POST localhost:3000/bulk_payments \
  -H 'Content-Type: application/json' -H 'Idempotency-Key: demo-422-funds' \
  -d '{"payer_firm_uuid": "8b2e4c71-0d3a-4f6e-b1c9-5a7d2e9f4c10",
       "payments": [{"amount": "5000", "payee_firm_uuid": "e5f18b3c-2a9d-4c07-8e6b-1d4a7f9c3b25", "description": "More than Lopez holds"}]}'
```

```json
{"error":{"code":"insufficient_funds","message":"The payer's balance does not cover the request total.","details":{"required_total":"5000.00"}}}
```

The other codes are `invalid_request` (400), `idempotency_key_reused` (409), `payee_balance_limit_exceeded` (422) and
`busy` (503). See [Error Scenarios](docs/specs/bulk-payments.md#error-scenarios) in the spec.

## How I worked

- **Tool.** Claude Code throughout.
- **Separate sessions** for bootstrap, spec, implementation and README, to keep each context small.
- **Spec-driven development (SDD).** I wrote the spec, [docs/specs/bulk-payments.md](docs/specs/bulk-payments.md),
  with Claude from the brief, using the `write-spec` skill. Its challenge step makes Claude question choices and
  propose alternatives, which settled what the brief leaves open before any code was written. I did not polish the
  spec's formatting.
- **Spec and plan before code.** The implementation started from the spec and a plan, and the `plan-challenger`
  subagent argued against the plan before coding.
- **Loop engineering.** I set up feedback loops in which the agents check and fix their own work, so they need little
  human input: [CLAUDE.md](CLAUDE.md), skills in [.claude/skills](.claude/skills) (`write-spec`, `test-cover`,
  `bug-fix`), review subagents in [.claude/agents](.claude/agents) (bugs, security, performance, tests, comments,
  DevOps), and a pre-commit hook that runs `bin/ci`. I corrected them where needed.
- **Human judgement where the agent's defaults fell short.** Two examples:
  - The agent wrote request specs in the default RSpec style: shared `let` and `before` setup with many small `it`
    blocks. I had it rewrite them so each scenario is one example with its setup and all checks inline, as argued in
    [Let's Not](https://thoughtbot.com/blog/lets-not). Each test then reads top to bottom without hidden shared setup.
  - The domain error `BulkPayments::Error` carried an HTTP status, so the business logic knew about HTTP. I had the
    agent move the status mapping into the controller.
- **Codex once, manually.** The app is small, so I did not set up Codex alongside Claude. I ran one Codex review by
  hand. It found one issue in the concurrency tests, which I passed to Claude to fix. On a real project I would add
  Codex as a review subagent with its own skills.
- **Transcripts.** The unedited Claude Code sessions are in [docs/chats](docs/chats), one file per session.

## Issues I ran into

None significant on my side. The agents struggled with the concurrency tests and solved them with little help; one
issue came from the manual Codex review. Such a test only proves something if the requests really contend for the
same rows, without relying on timing. In the final spec, each request runs on its own thread and connection. A barrier
connection holds the row locks and is released only when `pg_stat_activity` shows every request waiting on a lock.
The details are in the transcripts.

## Possible improvements

- **`BIGINT` money columns** to lift the $21.47M limit on balances and totals.
- **Async processing** for batches over 1,000 entries: return `202` and let the client poll, instead of holding locks
  in a long transaction.
- **Append-only ledger:** record every debit and credit and derive balances from them, for a full audit trail and
  reconciliation.
- **Transactional outbox:** write an event in the settlement transaction and publish it from a worker. Other services
  and background jobs then reliably learn about settled payments, even if the process dies after the commit.
- **Rate limiting** per payer or client, at the gateway or with Rails' `rate_limit`.
- **Structured logs and business events** with Rails 8.1's `Rails.event`, e.g. one event per settled or denied bulk
  payment.
- **Observability:** OpenTelemetry metrics and traces, with dashboards for latency, lock waits, `503 busy` rates and
  denials.
- **Load testing** with a tool like Grafana k6, to measure throughput and lock contention on busy firms.
- **Kubernetes manifests**, if production runs on Kubernetes: deployment, `/up` health probes, resource limits and a
  migration job.
- **Static types** with Sorbet or Steep (RBS), whichever the company's other Ruby services use.
- **An OpenAPI spec** generated from the request specs (e.g. with rswag), so clients can generate code from it.
- **Secrets scanning** with a tool like gitleaks, in the pre-commit hook and in CI.
- **Full CI.** The GitHub Actions workflow is the Rails default (Brakeman, bundler-audit, RuboCop). It should also
  run RSpec against PostgreSQL, as `bin/ci` does locally.
- **More AI tooling**, e.g. a QA subagent that tests the app end to end. This matters most in a monorepo with
  frontend apps.
- **A Codex review subagent** next to the existing reviewers, for a second opinion from another vendor's model.

## Two quick questions

**How much time did you spend on this task?** Less than 3 hours. That includes bootstrapping the repository, the app
and a minimal local AI harness, but not this README or the deployment instructions.

**How proud are you of your work?** Fairly proud. I think it shows a modern way of working with AI: spec-driven
development (SDD), planning before coding, skills, review subagents, separate sessions with context compaction, and
human correction where needed. Not very proud, because the service is not perfect or production-ready yet. With more
time, I would work through the improvements above.
