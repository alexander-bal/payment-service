class BulkPaymentsController < ApplicationController
  STATUS_BY_ERROR_CODE = {
    "invalid_request" => :bad_request,
    "payer_not_found" => :not_found,
    "idempotency_key_reused" => :conflict,
    "payee_not_found" => :unprocessable_content,
    "insufficient_funds" => :unprocessable_content,
    "payee_balance_limit_exceeded" => :unprocessable_content,
    "busy" => :service_unavailable
  }.freeze

  rescue_from StandardError do |error|
    Rails.error.report(error, handled: true)
    render json: { error: { code: "internal_error", message: "Unexpected failure." } }, status: :internal_server_error
  end

  rescue_from BulkPayments::Error do |error|
    render json: error.body, status: STATUS_BY_ERROR_CODE.fetch(error.code)
  end

  def index
    bulk_payments = BulkPayment
      .joins("JOIN firms payer ON payer.id = bulk_payments.payer_firm_id")
      .joins("JOIN payments ON payments.bulk_payment_id = bulk_payments.id")
      .group("bulk_payments.id", "payer.name")
      .order(id: :desc)
      .pluck("bulk_payments.id", "payer.name", "bulk_payments.total_amount_cents", Arel.sql("COUNT(payments.id)"),
        "bulk_payments.idempotency_key", "bulk_payments.created_at")

    render json: bulk_payments.map { |id, payer_name, total_amount_cents, payments_count, idempotency_key, created_at|
      { id:, payer_name:, total_amount: BulkPayments::Amount.format(total_amount_cents), payments_count:,
        idempotency_key:, created_at: }
    }
  end

  def create
    request_data = BulkPayments::RequestParser.call(
      raw_body: request.raw_post,
      idempotency_key: request.headers["Idempotency-Key"]
    )
    result = BulkPayments::Create.call(request_data)

    response.set_header("Idempotent-Replayed", "true") if result.replayed
    render json: result.body, status: :created
  end

  private

  # The body is always JSON, whatever Content-Type claims. Rails parses the body and query string for request logging
  # before any rescue_from applies, which answers a body such as {"description":"100%"} or a query of "x=%" with an
  # HTML 400.
  def process_action(*)
    request.set_header("CONTENT_TYPE", "application/json")
    super
  rescue ActionController::BadRequest
    rescue_with_handler(BulkPayments::Error.new("invalid_request", "The request is invalid.",
      { errors: [ { field: "query", message: "must be valid percent-encoded text" } ] }))
  end
end
