class Payment < ApplicationRecord
  belongs_to :payee_firm, class_name: "Firm"

  def readonly?
    persisted? || super
  end
end
