require "rails_helper"

RSpec.describe Payment, type: :model do
  it "is valid with factory defaults" do
    expect(build(:payment)).to be_valid
  end

  it "requires a positive amount" do
    expect(build(:payment, amount_cents: 0)).not_to be_valid
  end

  it "requires a 3-letter currency" do
    expect(build(:payment, currency: "US")).not_to be_valid
  end

  it "rejects unknown statuses" do
    expect(build(:payment, status: "bogus")).not_to be_valid
  end
end
