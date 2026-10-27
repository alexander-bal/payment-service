require "rails_helper"

RSpec.describe "Payments", type: :request do
  describe "GET /payments" do
    it "returns payments as JSON" do
      payment = create(:payment, amount_cents: 2_500)

      get "/payments"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to contain_exactly(
        a_hash_including("id" => payment.id, "amount_cents" => 2_500, "currency" => "USD")
      )
    end
  end

  describe "GET /up" do
    it "reports healthy" do
      get "/up"
      expect(response).to have_http_status(:ok)
    end
  end
end
