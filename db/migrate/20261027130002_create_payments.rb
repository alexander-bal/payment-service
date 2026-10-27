class CreatePayments < ActiveRecord::Migration[8.1]
  def change
    create_table :payments, id: :integer do |t|
      t.integer :payer_firm_id, null: false
      t.integer :payee_firm_id, null: false
      t.integer :amount_cents, null: false
      t.text :description, null: false
      t.integer :bulk_payment_id, null: false
    end

    add_index :payments, [ :bulk_payment_id, :id ]
    add_index :payments, :payee_firm_id

    add_foreign_key :payments, :firms, column: :payer_firm_id
    add_foreign_key :payments, :firms, column: :payee_firm_id
    # A payment's payer is always its bulk payment's payer.
    add_foreign_key :payments, :bulk_payments, column: [ :bulk_payment_id, :payer_firm_id ], primary_key: [ :id, :payer_firm_id ]

    add_check_constraint :payments, "amount_cents > 0", name: "payments_amount_positive"
    add_check_constraint :payments, "payer_firm_id <> payee_firm_id", name: "payments_payee_not_payer"
    add_check_constraint :payments,
      "char_length(description) BETWEEN 1 AND 255 AND description ~ '[^[:space:]]'",
      name: "payments_description_present"
  end
end
