class BulkPayment < ApplicationRecord
  def readonly?
    persisted? || super
  end
end
