module BulkPayments
  class Error < StandardError
    attr_reader :code, :details

    def initialize(code, message, details = nil)
      super(message)
      @code = code
      @details = details
    end

    def body
      { error: { code:, message:, details: }.compact }
    end
  end
end
