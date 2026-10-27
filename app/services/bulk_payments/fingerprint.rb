module BulkPayments
  module Fingerprint
    def self.call(request)
      entries = request.entries.map { |entry| [ entry.payee_uuid, entry.amount_cents, entry.description ] }
      Digest::SHA256.hexdigest(JSON.generate([ request.payer_uuid, entries ]))
    end
  end
end
