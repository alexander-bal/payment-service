class PaymentsController < ApplicationController
  def index
    render json: Payment.order(:id)
  end
end
