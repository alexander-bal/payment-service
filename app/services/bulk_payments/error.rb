module BulkPayments
  class Error < StandardError
    attr_reader :status, :code, :details

    def initialize(status, code, message, details = nil)
      super(message)
      @status = status
      @code = code
      @details = details
    end

    def body
      { error: { code:, message:, details: }.compact }
    end
  end
end
