module BulkPayments
  # Builds the response from stored rows, so the original response and every replay are identical.
  module Serializer
    def self.call(bulk_payment)
      payments = Payment.where(bulk_payment_id: bulk_payment.id).joins(:payee_firm).order(:id)
        .pluck("payments.id", "firms.uuid", "payments.amount_cents", "payments.description")

      {
        id: bulk_payment.id,
        payer_firm_uuid: Firm.where(id: bulk_payment.payer_firm_id).pick(:uuid),
        total_amount: Amount.format(bulk_payment.total_amount_cents),
        payments: payments.map do |id, payee_firm_uuid, amount_cents, description|
          { id:, payee_firm_uuid:, amount: Amount.format(amount_cents), description: }
        end
      }
    end
  end
end
