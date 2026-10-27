FactoryBot.define do
  factory :firm do
    sequence(:name) { |n| "Firm #{n}" }
    balance_cents { 100_000 }
    uuid { SecureRandom.uuid }
  end
end
