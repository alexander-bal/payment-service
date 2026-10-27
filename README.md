# Payment Service

Rails API that settles bulk payments between firms. `POST /bulk_payments` settles one payer firm's payments to many
payees as a single all-or-nothing change. The full contract is in
[docs/specs/bulk-payments.md](docs/specs/bulk-payments.md).

## Prerequisites

- Docker with Compose v2 (`docker compose version`)
- For the native setup only: Ruby 4.0.9 (`mise install` reads `mise.toml`) and the PostgreSQL client library
  (`brew install libpq` on macOS)

PostgreSQL always runs in Docker (`compose.yml`), published on `127.0.0.1:54331`.

## Run with Docker (Recommended)

```sh
docker compose --profile app up --build
```

This starts PostgreSQL and the Rails app in development mode on <http://localhost:3000>. On first start it creates and
migrates the development and test databases and seeds the three firms. The source is bind-mounted, so code changes
reload without a restart. Keep `--build` so a changed `Gemfile.lock` gets installed into the image.

Check it is up from another terminal:

```sh
curl -i localhost:3000/up    # HTTP/1.1 200 OK
```

Stop with `Ctrl-C`, or `docker compose --profile app down`. Add `-v` to also delete the database volume.

Run any Rails command in the running container with `docker compose --profile app exec app <command>`, e.g.
`docker compose --profile app exec app bin/rails console`.

## Run natively

```sh
docker compose up -d --wait db   # PostgreSQL only
bundle install
bin/rails db:prepare             # creates, migrates and seeds the development and test databases
bin/rails server                 # http://localhost:3000
```

The native server and the Docker app both use port 3000, so run only one at a time.

## Run the tests

Tests run against a real PostgreSQL, including a concurrency spec that forces lock contention across separate
connections.

```sh
# Docker
docker compose --profile app run --rm app bundle exec rspec

# Native (needs `docker compose up -d --wait db`)
bundle exec rspec
```

`bin/ci` runs the full CI locally: setup, RuboCop, bundler-audit, Brakeman and RSpec.

## Verify the acceptance case (AC-1)

This replays [AC-1](docs/specs/bulk-payments.md#ac-1-brief-sample-request) against a running app. The commands below
are for the Docker setup. For the native setup, drop the `docker compose --profile app exec app` prefix.

1. Reset the firms to the brief's seed balances. This deletes all bulk payments:

   ```sh
   docker compose --profile app exec app bin/rails db:seed:replant
   ```

2. Submit the brief's sample request:

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

   Expected: `HTTP/1.1 201 Created` and this body. Ids are 1, 1, 2, 3 only on a fresh database, since a replant does
   not reset id sequences:

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

   Expected (before: 50000.00 / 500.00 / 2000.00, total 52500.00 both before and after):

   ```
   Pinecrest CPA Group  36748.75
   Lopez Bookkeeping    1700.75
   Nair Tax Services    14050.50
   ```

4. Send the same curl again. It returns the same 201 body with an `idempotent-replayed: true` header, and the balances
   don't change.

## Error examples

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

**422 `payee_not_found`**: one or more unknown payee firms. Nothing is settled, including the valid entries.

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

**422 `insufficient_funds`**: Lopez Bookkeeping (balance $500.00, or $1,700.75 after AC-1) tries to pay $5,000. The
details carry the required total but never the payer's balance.

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

## Git hooks

A pre-commit hook runs `bin/ci` against the staged changes. Install it once after `bundle install`:

```sh
bundle exec lefthook install
```

Skip it for a single commit with `LEFTHOOK=0 git commit ...`.
