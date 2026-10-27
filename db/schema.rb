# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_10_27_130002) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "bulk_payments", id: :serial, force: :cascade do |t|
    t.integer "payer_firm_id", null: false
    t.text "idempotency_key", null: false
    t.text "request_fingerprint", null: false
    t.integer "total_amount_cents", null: false
    t.timestamptz "created_at", default: -> { "now()" }, null: false
    t.index ["payer_firm_id", "created_at", "id"], name: "index_bulk_payments_on_payer_firm_id_and_created_at_and_id", order: { created_at: :desc, id: :desc }
    t.index ["payer_firm_id", "idempotency_key"], name: "index_bulk_payments_on_payer_firm_id_and_idempotency_key", unique: true
    t.check_constraint "idempotency_key ~ '^[ -~]{1,255}$'::text", name: "bulk_payments_idempotency_key_format"
    t.check_constraint "request_fingerprint ~ '^[0-9a-f]{64}$'::text", name: "bulk_payments_fingerprint_format"
    t.check_constraint "total_amount_cents > 0", name: "bulk_payments_total_positive"
    t.unique_constraint ["id", "payer_firm_id"]
  end

  create_table "firms", id: :serial, force: :cascade do |t|
    t.text "name", null: false
    t.integer "balance_cents", null: false
    t.text "uuid", null: false
    t.index ["uuid"], name: "index_firms_on_uuid", unique: true
    t.check_constraint "balance_cents >= 0", name: "firms_balance_cents_non_negative"
    t.check_constraint "uuid ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'::text", name: "firms_uuid_canonical"
  end

  create_table "payments", id: :serial, force: :cascade do |t|
    t.integer "payer_firm_id", null: false
    t.integer "payee_firm_id", null: false
    t.integer "amount_cents", null: false
    t.text "description", null: false
    t.integer "bulk_payment_id", null: false
    t.index ["bulk_payment_id", "id"], name: "index_payments_on_bulk_payment_id_and_id"
    t.index ["payee_firm_id"], name: "index_payments_on_payee_firm_id"
    t.check_constraint "amount_cents > 0", name: "payments_amount_positive"
    t.check_constraint "char_length(description) >= 1 AND char_length(description) <= 255 AND description ~ '[^[:space:]]'::text", name: "payments_description_present"
    t.check_constraint "payer_firm_id <> payee_firm_id", name: "payments_payee_not_payer"
  end

  add_foreign_key "bulk_payments", "firms", column: "payer_firm_id"
  add_foreign_key "payments", "bulk_payments", column: ["bulk_payment_id", "payer_firm_id"], primary_key: ["id", "payer_firm_id"]
  add_foreign_key "payments", "firms", column: "payee_firm_id"
  add_foreign_key "payments", "firms", column: "payer_firm_id"
end
