class Payment < ApplicationRecord
  STATUSES = %w[pending succeeded failed].freeze

  validates :amount_cents, presence: true, numericality: { only_integer: true, greater_than: 0 }
  validates :currency, presence: true, length: { is: 3 }
  validates :status, inclusion: { in: STATUSES }
end
