class CreateBulkPayments < ActiveRecord::Migration[8.1]
  def change
    create_table :bulk_payments, id: :integer do |t|
      t.references :payer_firm, type: :integer, null: false, index: false, foreign_key: { to_table: :firms }
      t.text :idempotency_key, null: false
      t.text :request_fingerprint, null: false
      t.integer :total_amount_cents, null: false
      t.timestamptz :created_at, null: false, default: -> { "now()" }
    end

    add_index :bulk_payments, [ :payer_firm_id, :idempotency_key ], unique: true
    add_index :bulk_payments, [ :payer_firm_id, :created_at, :id ], order: { created_at: :desc, id: :desc }
    # Target of the composite foreign key from payments.
    add_unique_constraint :bulk_payments, [ :id, :payer_firm_id ]

    add_check_constraint :bulk_payments, "total_amount_cents > 0", name: "bulk_payments_total_positive"
    add_check_constraint :bulk_payments, "idempotency_key ~ '^[ -~]{1,255}$'", name: "bulk_payments_idempotency_key_format"
    add_check_constraint :bulk_payments, "request_fingerprint ~ '^[0-9a-f]{64}$'", name: "bulk_payments_fingerprint_format"
  end
end
