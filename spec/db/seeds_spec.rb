require "rails_helper"

RSpec.describe "db/seeds.rb" do
  def seed
    load Rails.root.join("db/seeds.rb")
  end

  it "inserts the brief's three firms" do
    seed

    expect(Firm.order(:id).pluck(:id, :name, :balance_cents, :uuid)).to eq([
      [ 1, "Pinecrest CPA Group", 5_000_000, PINECREST ],
      [ 2, "Lopez Bookkeeping", 50_000, LOPEZ ],
      [ 3, "Nair Tax Services", 200_000, NAIR ]
    ])
  end

  it "is idempotent" do
    seed
    Firm.where(uuid: LOPEZ).update_all(balance_cents: 1)

    expect { seed }.not_to change(Firm, :count)
    expect(Firm.find_by(uuid: LOPEZ).balance_cents).to eq(1)
  end

  it "leaves the id sequence past the seeded ids" do
    ActiveRecord::Base.connection.execute("SELECT setval('firms_id_seq', 1, false)")
    seed

    expect(create(:firm).id).to be > 3
  end
end
