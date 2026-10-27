require "rails_helper"

RSpec.describe "Read endpoints", type: :request do
  it "lists firms, payments and bulk payments", :aggregate_failures do
    seed_brief_firms

    get "/bulk_payments"
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq([])

    get "/payments"
    expect(response.parsed_body).to eq([])

    post_bulk(bulk_body([ entry(NAIR, "6250", "Overflow"), entry(LOPEZ, "1200.75", "Cleanup") ]), key: "first")
    post_bulk(bulk_body([ entry(PINECREST, "0.05", "Refund") ], payer: LOPEZ), key: "second")
    first, second = BulkPayment.order(:id).to_a

    get "/firms"
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq([
      { "id" => 1, "uuid" => PINECREST, "name" => "Pinecrest CPA Group", "balance" => "42549.30" },
      { "id" => 2, "uuid" => LOPEZ, "name" => "Lopez Bookkeeping", "balance" => "1700.70" },
      { "id" => 3, "uuid" => NAIR, "name" => "Nair Tax Services", "balance" => "8250.00" }
    ])

    get "/payments"
    expect(response).to have_http_status(:ok)
    ids = Payment.order(id: :desc).pluck(:id)
    expect(response.parsed_body).to eq([
      { "id" => ids[0], "bulk_payment_id" => second.id, "payer_name" => "Lopez Bookkeeping",
        "payee_name" => "Pinecrest CPA Group", "amount" => "0.05", "description" => "Refund" },
      { "id" => ids[1], "bulk_payment_id" => first.id, "payer_name" => "Pinecrest CPA Group",
        "payee_name" => "Lopez Bookkeeping", "amount" => "1200.75", "description" => "Cleanup" },
      { "id" => ids[2], "bulk_payment_id" => first.id, "payer_name" => "Pinecrest CPA Group",
        "payee_name" => "Nair Tax Services", "amount" => "6250.00", "description" => "Overflow" }
    ])

    get "/bulk_payments"
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq([
      { "id" => second.id, "payer_name" => "Lopez Bookkeeping", "total_amount" => "0.05", "payments_count" => 1,
        "idempotency_key" => "second", "created_at" => second.created_at.as_json },
      { "id" => first.id, "payer_name" => "Pinecrest CPA Group", "total_amount" => "7450.75", "payments_count" => 2,
        "idempotency_key" => "first", "created_at" => first.created_at.as_json }
    ])
  end
end
