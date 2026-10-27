class CreateFirms < ActiveRecord::Migration[8.1]
  def change
    create_table :firms, id: :integer do |t|
      t.text :name, null: false
      t.integer :balance_cents, null: false
      t.text :uuid, null: false
    end

    add_index :firms, :uuid, unique: true
    add_check_constraint :firms, "balance_cents >= 0", name: "firms_balance_cents_non_negative"
    add_check_constraint :firms,
      "uuid ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'",
      name: "firms_uuid_canonical"
  end
end
