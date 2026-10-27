module BulkPayments
  Request = Data.define(:idempotency_key, :payer_uuid, :entries) do
    def total_cents = entries.sum(&:amount_cents)
  end

  Request::Entry = Data.define(:payee_uuid, :amount_cents, :description)
end
