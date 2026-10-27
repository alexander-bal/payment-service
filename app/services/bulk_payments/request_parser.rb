module BulkPayments
  # Validates the request shape without touching the database; every offending field is reported, not only the first.
  class RequestParser
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    IDEMPOTENCY_KEY = /\A[ -~]{1,255}\z/
    BLANK = /\A[[:space:]]*\z/
    MAX_ENTRIES = 1_000
    MAX_DESCRIPTION_LENGTH = 255

    def self.call(raw_body:, idempotency_key:)
      new(raw_body, idempotency_key).call
    end

    def initialize(raw_body, idempotency_key)
      @raw_body = raw_body
      @idempotency_key = idempotency_key
      @errors = []
    end

    def call
      validate_idempotency_key
      body = parse_body
      if body
        payer_uuid = parse_uuid(body, "payer_firm_uuid")
        entries = parse_entries(body["payments"], payer_uuid)
      end
      fail_with_errors if @errors.any?

      Request.new(idempotency_key: @idempotency_key, payer_uuid:, entries:)
    end

    private

    def validate_idempotency_key
      return if @idempotency_key.is_a?(String) && @idempotency_key.match?(IDEMPOTENCY_KEY)

      add_error("Idempotency-Key", "must be 1 to 255 printable ASCII characters")
    end

    def parse_body
      body = JSON.parse(@raw_body.to_s)
      return body if body.is_a?(Hash)

      add_error("body", "must be a JSON object")
      nil
    rescue JSON::ParserError, EncodingError
      add_error("body", "must be valid JSON")
      nil
    end

    def parse_uuid(source, field, index: nil)
      value = source[field]
      if value.nil?
        add_error(field, "is required", index:)
      elsif !value.is_a?(String)
        add_error(field, "must be a string", index:)
      elsif !(value.valid_encoding? && value.match?(UUID))
        add_error(field, "must be a UUID", index:)
      else
        value.downcase
      end
    end

    def parse_entries(payments, payer_uuid)
      if payments.nil?
        add_error("payments", "is required")
      elsif !payments.is_a?(Array)
        add_error("payments", "must be an array")
      elsif payments.empty?
        add_error("payments", "must not be empty")
      elsif payments.size > MAX_ENTRIES
        add_error("payments", "must have at most #{MAX_ENTRIES} entries")
      else
        entries = payments.each_with_index.map { |payment, index| parse_entry(payment, index, payer_uuid) }
        check_total(entries.compact)
        entries.all? ? entries : nil
      end
    end

    def parse_entry(payment, index, payer_uuid)
      return add_error("payments", "must be an object", index:) unless payment.is_a?(Hash)

      payee_uuid = parse_uuid(payment, "payee_firm_uuid", index:)
      add_error("payee_firm_uuid", "must differ from payer_firm_uuid", index:) if payee_uuid && payee_uuid == payer_uuid
      amount_cents = parse_amount(payment, index)
      description = parse_description(payment, index)

      if payee_uuid && amount_cents && description && payee_uuid != payer_uuid
        Request::Entry.new(payee_uuid:, amount_cents:, description:)
      end
    end

    def parse_amount(payment, index)
      value = payment["amount"]
      return add_error("amount", "is required", index:) if value.nil?
      return add_error("amount", "must be a string", index:) unless value.is_a?(String)

      cents = Amount.parse(value)
      if cents.nil?
        add_error("amount", "must be dollars with at most two decimal places, e.g. \"12.50\"", index:)
      elsif !cents.between?(1, Amount::MAX_CENTS)
        add_error("amount", "must be between 0.01 and #{Amount.format(Amount::MAX_CENTS)}", index:)
      else
        cents
      end
    end

    def parse_description(payment, index)
      value = payment["description"]
      return add_error("description", "is required", index:) if value.nil?
      return add_error("description", "must be a string", index:) unless value.is_a?(String)

      if !value.valid_encoding? || value.include?("\0")
        add_error("description", "must be valid text", index:)
      elsif value.match?(BLANK)
        add_error("description", "must not be blank", index:)
      elsif value.length > MAX_DESCRIPTION_LENGTH
        add_error("description", "must be at most #{MAX_DESCRIPTION_LENGTH} characters", index:)
      else
        value
      end
    end

    def check_total(entries)
      return if entries.sum(&:amount_cents) <= Amount::MAX_CENTS

      add_error("payments", "total must not exceed #{Amount.format(Amount::MAX_CENTS)}")
    end

    # Returns nil so callers can use it as the value of an invalid field.
    def add_error(field, message, index: nil)
      @errors << { index:, field:, message: }.compact
      nil
    end

    def fail_with_errors
      raise Error.new(400, "invalid_request", "The request is invalid.", { errors: @errors })
    end
  end
end
