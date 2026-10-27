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
