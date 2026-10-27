require "rails_helper"

RSpec.describe "Health", type: :request do
  it "reports healthy" do
    get "/up"
    expect(response).to have_http_status(:ok)
  end
end
