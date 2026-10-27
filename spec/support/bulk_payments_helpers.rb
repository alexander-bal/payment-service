PINECREST = "3f1c9a2e-7b4d-4c1e-9a55-2d8e6f0b7c41"
LOPEZ = "8b2e4c71-0d3a-4f6e-b1c9-5a7d2e9f4c10"
NAIR = "e5f18b3c-2a9d-4c07-8e6b-1d4a7f9c3b25"
UNKNOWN = "00000000-0000-4000-8000-000000000000"

module BulkPaymentsHelpers
  # The brief's three firms, inserted with the brief's own statement.
  def seed_brief_firms
    ActiveRecord::Base.connection.execute(<<~SQL)
      INSERT INTO firms (id, name, balance_cents, uuid)
      VALUES (1, 'Pinecrest CPA Group', 5000000, '#{PINECREST}'),
             (2, 'Lopez Bookkeeping', 50000, '#{LOPEZ}'),
             (3, 'Nair Tax Services', 200000, '#{NAIR}');
    SQL
    ActiveRecord::Base.connection.reset_pk_sequence!("firms")
  end

  def balances
    Firm.order(:id).pluck(:uuid, :balance_cents).to_h
  end

  def entry(payee, amount, description = "Invoice")
    { "amount" => amount, "payee_firm_uuid" => payee, "description" => description }
  end

  def bulk_body(payments, payer: PINECREST)
    { "payer_firm_uuid" => payer, "payments" => payments }
  end

  def post_bulk(body, key: "key-1", headers: {})
    payload = body.is_a?(String) ? body : body.to_json
    request_headers = { "CONTENT_TYPE" => "application/json", "Idempotency-Key" => key }.compact.merge(headers)
    post "/bulk_payments", params: payload, headers: request_headers
  end

  def error_body
    response.parsed_body.fetch("error")
  end

  # Runs a block against the current data and rolls its writes back, so scenarios inside one example start from the
  # same state. The savepoint is not joinable, so the endpoint's own transaction nests as it does in production.
  def scenario(label)
    aggregate_failures(label) do
      ActiveRecord::Base.transaction(requires_new: true, joinable: false) do
        yield
        raise ActiveRecord::Rollback
      end
    end
  end
end

RSpec.configure do |config|
  config.include BulkPaymentsHelpers, type: :request
end
