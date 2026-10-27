FactoryBot.define do
  factory :payment do
    amount_cents { 1_000 }
    currency { "USD" }
    status { "pending" }
  end
end
