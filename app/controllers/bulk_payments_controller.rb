class BulkPaymentsController < ApplicationController
  rescue_from StandardError do |error|
    Rails.error.report(error, handled: true)
    render json: { error: { code: "internal_error", message: "Unexpected failure." } }, status: :internal_server_error
  end

  rescue_from BulkPayments::Error do |error|
    render json: error.body, status: error.status
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
end
