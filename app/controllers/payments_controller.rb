class PaymentsController < ApplicationController
  def index
    payments = Payment
      .joins("JOIN firms payer ON payer.id = payments.payer_firm_id")
      .joins("JOIN firms payee ON payee.id = payments.payee_firm_id")
      .order(id: :desc)
      .pluck("payments.id", "payments.bulk_payment_id", "payer.name", "payee.name", "payments.amount_cents",
        "payments.description")

    render json: payments.map { |id, bulk_payment_id, payer_name, payee_name, amount_cents, description|
      { id:, bulk_payment_id:, payer_name:, payee_name:, amount: BulkPayments::Amount.format(amount_cents), description: }
    }
  end
end
