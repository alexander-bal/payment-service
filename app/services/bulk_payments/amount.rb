module BulkPayments
  # Money is integer cents end to end; amounts never pass through Float or BigDecimal.
  module Amount
    MAX_CENTS = 2_147_483_647
    OVER_MAX = MAX_CENTS + 1
    FORMAT = /\A(\d+)(?:\.(\d{1,2}))?\z/

    # Cents for a string like "5800.5", nil when the string is not an amount.
    # Anything beyond MAX_CENTS collapses to OVER_MAX so huge digit strings never become huge integers.
    def self.parse(value)
      return unless value.is_a?(String) && value.valid_encoding?

      match = FORMAT.match(value) or return
      dollars = match[1].sub(/\A0+(?=\d)/, "")
      return OVER_MAX if dollars.length > 10

      dollars.to_i * 100 + match[2].to_s.ljust(2, "0").to_i
    end

    def self.format(cents)
      Kernel.format("%d.%02d", cents / 100, cents % 100)
    end
  end
end
