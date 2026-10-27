require "rails_helper"

RSpec.describe "database constraints" do
  let(:connection) { ActiveRecord::Base.connection }
  let!(:payer) { create(:firm) }
  let!(:payee) { create(:firm) }
  let(:fingerprint) { "a" * 64 }

  def insert_firm(name: "F", balance_cents: 0, uuid: SecureRandom.uuid)
    connection.execute(ActiveRecord::Base.sanitize_sql_array(
      [ "INSERT INTO firms (name, balance_cents, uuid) VALUES (?, ?, ?)", name, balance_cents, uuid ]
    ))
  end

  def insert_bulk_payment(payer_firm_id: payer.id, key: "k", fingerprint: self.fingerprint, total: 100)
    connection.execute(ActiveRecord::Base.sanitize_sql_array([
      "INSERT INTO bulk_payments (payer_firm_id, idempotency_key, request_fingerprint, total_amount_cents) VALUES (?, ?, ?, ?)",
      payer_firm_id, key, fingerprint, total
    ]))
  end

  def insert_payment(bulk_payment_id:, payer_firm_id: payer.id, payee_firm_id: payee.id, amount_cents: 100, description: "d")
    connection.execute(ActiveRecord::Base.sanitize_sql_array([
      "INSERT INTO payments (bulk_payment_id, payer_firm_id, payee_firm_id, amount_cents, description) VALUES (?, ?, ?, ?, ?)",
      bulk_payment_id, payer_firm_id, payee_firm_id, amount_cents, description
    ]))
  end

  def reject(error = ActiveRecord::StatementInvalid, &block)
    expect { ActiveRecord::Base.transaction(requires_new: true, &block) }.to raise_error(error)
  end

  describe "firms" do
    it "matches the brief's columns and types" do
      columns = connection.columns(:firms).to_h { |column| [ column.name, column.sql_type ] }
      expect(columns).to eq("id" => "integer", "name" => "text", "balance_cents" => "integer", "uuid" => "text")
    end

    it "keeps balances from going negative" do
      reject(ActiveRecord::StatementInvalid) { insert_firm(balance_cents: -1) }
      reject(ActiveRecord::StatementInvalid) { payer.update_columns(balance_cents: -1) }
    end

    it "caps balances at the 32-bit maximum" do
      reject(ActiveRecord::RangeError) { connection.execute("UPDATE firms SET balance_cents = 2147483648 WHERE id = #{payer.id}") }
      expect { payer.update_columns(balance_cents: 2_147_483_647) }.not_to raise_error
    end

    it "requires unique, canonical lowercase uuids" do
      reject(ActiveRecord::RecordNotUnique) { insert_firm(uuid: payer.uuid) }
      reject { insert_firm(uuid: payer.uuid.upcase) }
      reject { insert_firm(uuid: "not-a-uuid") }
    end

    it "requires every column" do
      reject(ActiveRecord::NotNullViolation) { connection.execute("INSERT INTO firms (name, balance_cents) VALUES ('x', 0)") }
      reject(ActiveRecord::NotNullViolation) { connection.execute("INSERT INTO firms (balance_cents, uuid) VALUES (0, '#{SecureRandom.uuid}')") }
      reject(ActiveRecord::NotNullViolation) { connection.execute("INSERT INTO firms (name, uuid) VALUES ('x', '#{SecureRandom.uuid}')") }
    end
  end

  describe "payments" do
    it "matches the brief's columns and types, plus bulk_payment_id" do
      columns = connection.columns(:payments).to_h { |column| [ column.name, column.sql_type ] }
      expect(columns).to eq(
        "id" => "integer", "payer_firm_id" => "integer", "payee_firm_id" => "integer", "amount_cents" => "integer",
        "description" => "text", "bulk_payment_id" => "integer"
      )
    end

    before { insert_bulk_payment }
    let(:bulk_id) { connection.select_value("SELECT id FROM bulk_payments") }

    it "accepts a well-formed row" do
      expect { insert_payment(bulk_payment_id: bulk_id) }.not_to raise_error
    end

    it "requires a positive amount" do
      reject { insert_payment(bulk_payment_id: bulk_id, amount_cents: 0) }
      reject { insert_payment(bulk_payment_id: bulk_id, amount_cents: -5) }
    end

    it "forbids paying oneself" do
      reject { insert_payment(bulk_payment_id: bulk_id, payee_firm_id: payer.id) }
    end

    it "requires a non-blank description of at most 255 characters" do
      reject { insert_payment(bulk_payment_id: bulk_id, description: "") }
      reject { insert_payment(bulk_payment_id: bulk_id, description: "  \t ") }
      reject { insert_payment(bulk_payment_id: bulk_id, description: "x" * 256) }
      expect { insert_payment(bulk_payment_id: bulk_id, description: "é" * 255) }.not_to raise_error
    end

    it "requires existing firms and bulk payment" do
      reject(ActiveRecord::InvalidForeignKey) { insert_payment(bulk_payment_id: bulk_id, payee_firm_id: 999_999) }
      reject(ActiveRecord::InvalidForeignKey) { insert_payment(bulk_payment_id: 999_999) }
    end

    it "requires the payment's payer to be its bulk payment's payer" do
      reject(ActiveRecord::InvalidForeignKey) { insert_payment(bulk_payment_id: bulk_id, payer_firm_id: payee.id, payee_firm_id: payer.id) }
    end

    it "requires every column" do
      %w[payer_firm_id payee_firm_id amount_cents description bulk_payment_id].each do |column|
        columns = { "payer_firm_id" => payer.id, "payee_firm_id" => payee.id, "amount_cents" => 1, "description" => "'d'",
                    "bulk_payment_id" => bulk_id }.except(column)
        reject(ActiveRecord::NotNullViolation) do
          connection.execute("INSERT INTO payments (#{columns.keys.join(', ')}) VALUES (#{columns.values.join(', ')})")
        end
      end
    end
  end

  describe "bulk_payments" do
    it "scopes idempotency keys to the payer" do
      insert_bulk_payment(key: "same")
      expect { insert_bulk_payment(payer_firm_id: payee.id, key: "same") }.not_to raise_error
      reject(ActiveRecord::RecordNotUnique) { insert_bulk_payment(key: "same") }
    end

    it "requires a positive total" do
      reject { insert_bulk_payment(total: 0) }
    end

    it "requires a printable ASCII key of 1 to 255 characters" do
      reject { insert_bulk_payment(key: "") }
      reject { insert_bulk_payment(key: "a" * 256) }
      reject { insert_bulk_payment(key: "é") }
      reject { insert_bulk_payment(key: "line\nbreak") }
      expect { insert_bulk_payment(key: "a" * 255) }.not_to raise_error
    end

    it "requires a sha256 hex fingerprint" do
      reject { insert_bulk_payment(fingerprint: "short") }
      reject { insert_bulk_payment(fingerprint: "A" * 64) }
    end

    it "requires an existing payer" do
      reject(ActiveRecord::InvalidForeignKey) { insert_bulk_payment(payer_firm_id: 999_999) }
    end

    it "requires every column" do
      %w[payer_firm_id idempotency_key request_fingerprint total_amount_cents].each do |column|
        columns = { "payer_firm_id" => payer.id, "idempotency_key" => "'k'", "request_fingerprint" => "'#{fingerprint}'",
                    "total_amount_cents" => 100 }.except(column)
        reject(ActiveRecord::NotNullViolation) do
          connection.execute("INSERT INTO bulk_payments (#{columns.keys.join(', ')}) VALUES (#{columns.values.join(', ')})")
        end
      end
    end

    it "indexes each payer's bulk payments newest first" do
      index = connection.indexes(:bulk_payments).find { |candidate| candidate.columns == %w[payer_firm_id created_at id] }

      expect(index.orders).to eq("created_at" => :desc, "id" => :desc)
    end

    it "assigns created_at itself" do
      insert_bulk_payment
      expect(connection.select_value("SELECT created_at FROM bulk_payments")).to be_within(5.seconds).of(Time.current)
    end
  end
end
