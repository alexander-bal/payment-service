# README

This README would normally document whatever steps are necessary to get the
application up and running.

Things you may want to cover:

* Ruby version

* System dependencies

* Configuration

* Database creation

* Database initialization

* How to run the test suite

* Services (job queues, cache servers, search engines, etc.)

* Deployment instructions

* ...

## Git hooks

A pre-commit hook runs `bin/ci` against the staged changes. Install it once after `bundle install`:

```sh
bundle exec lefthook install
```

Skip it for a single commit with `LEFTHOOK=0 git commit ...`.

## Bulk payments

`POST /bulk_payments` settles one payer firm's payments to many payees as a single all-or-nothing change. The full
contract is in [docs/specs/bulk-payments.md](docs/specs/bulk-payments.md).

```sh
docker compose up -d db          # PostgreSQL on 127.0.0.1:54331
bin/rails db:create db:migrate db:seed
bin/rails server

curl -i -X POST localhost:3000/bulk_payments \
  -H 'Content-Type: application/json' -H 'Idempotency-Key: demo-1' \
  -d '{"payer_firm_uuid":"3f1c9a2e-7b4d-4c1e-9a55-2d8e6f0b7c41","payments":[
        {"amount":"1200.75","payee_firm_uuid":"8b2e4c71-0d3a-4f6e-b1c9-5a7d2e9f4c10","description":"Cleanup"}]}'
```

Tests run against a real PostgreSQL (`bundle exec rspec`), including a concurrency spec that forces lock contention
across separate connections. The pre-commit hook runs them through `bin/ci`.
