class FirmsController < ApplicationController
  def index
    firms = Firm.order(:id).pluck(:id, :uuid, :name, :balance_cents)

    render json: firms.map { |id, uuid, name, balance_cents|
      { id:, uuid:, name:, balance: BulkPayments::Amount.format(balance_cents) }
    }
  end
end
