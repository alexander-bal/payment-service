module BulkPayments
  # Everything decidable without locks happens before the transaction opens. The transaction only locks the
  # firms, re-checks the idempotency key, checks funds and writes.
  class Create
    Result = Data.define(:body, :replayed)

    def self.call(request)
      new(request).call
    end

    def initialize(request)
      @request = request
    end

    def call
      payer = Firm.find_by(uuid: @request.payer_uuid) || raise(payer_not_found)
      fingerprint = Fingerprint.call(@request)

      existing = find_existing(payer)
      return Result.new(body: Serializer.call(verified(existing, fingerprint)), replayed: true) if existing

      payee_ids = resolve_payees
      bulk_payment, replayed = settle(payer, payee_ids, fingerprint)
      Result.new(body: Serializer.call(bulk_payment), replayed:)
    end

    private

    def find_existing(payer)
      BulkPayment.find_by(payer_firm_id: payer.id, idempotency_key: @request.idempotency_key)
    end

    def verified(existing, fingerprint)
      return existing if existing.request_fingerprint == fingerprint

      raise Error.new("idempotency_key_reused", "The Idempotency-Key was already used for a different request.")
    end

    def resolve_payees
      uuids = @request.entries.map(&:payee_uuid).uniq
      ids_by_uuid = Firm.where(uuid: uuids).pluck(:uuid, :id).to_h
      unknown = uuids - ids_by_uuid.keys
      return ids_by_uuid if unknown.empty?

      raise Error.new("payee_not_found", "Some payee firms do not exist.", { unknown_payee_firm_uuids: unknown })
    end

    def settle(payer, payee_ids, fingerprint)
      BulkPayment.transaction do
        balances = lock_firms([ payer.id, *payee_ids.values ])

        existing = find_existing(payer)
        next [ verified(existing, fingerprint), true ] if existing

        credits = check_funds(payer, payee_ids, balances)
        bulk_payment = BulkPayment.create!(
          payer_firm_id: payer.id,
          idempotency_key: @request.idempotency_key,
          request_fingerprint: fingerprint,
          total_amount_cents: @request.total_cents
        )
        insert_payments(bulk_payment, payee_ids)
        apply_balance_changes(payer, credits)
        [ bulk_payment, false ]
      end
    end

    # One ordered FOR UPDATE statement takes every lock in ascending id order. The statement timeout bounds the
    # wait for the whole set, and is lifted again so it never limits the writes that follow.
    def lock_firms(ids)
      connection = Firm.connection
      connection.execute(Firm.sanitize_sql_array([ "SET LOCAL statement_timeout = ?", lock_wait_ms ]))
      balances = Firm.where(id: ids).order(:id).lock.pluck(:id, :balance_cents).to_h
      connection.execute("SET LOCAL statement_timeout = DEFAULT")
      balances
    rescue ActiveRecord::QueryCanceled
      raise Error.new("busy", "The firms are locked by other requests. Retry shortly.")
    end

    def lock_wait_ms
      Integer(Rails.configuration.x.bulk_payments.lock_wait_ms)
    end

    # Returns the credit per payee firm id.
    def check_funds(payer, payee_ids, balances)
      total = @request.total_cents
      if balances.fetch(payer.id) < total
        raise Error.new("insufficient_funds", "The payer's balance does not cover the request total.",
          { required_total: Amount.format(total) })
      end

      credits = Hash.new(0)
      @request.entries.each { |entry| credits[payee_ids.fetch(entry.payee_uuid)] += entry.amount_cents }

      over_limit = credits.select { |id, credit| balances.fetch(id) + credit > Amount::MAX_CENTS }.keys
      if over_limit.any?
        uuids = payee_ids.select { |_uuid, id| over_limit.include?(id) }.keys
        raise Error.new("payee_balance_limit_exceeded", "Some payee balances would exceed the maximum.",
          { payee_firm_uuids: uuids })
      end

      credits
    end

    # Ids are drawn in one statement and sorted, so they ascend in request order within the bulk payment.
    def insert_payments(bulk_payment, payee_ids)
      entries = @request.entries
      ids = Payment.connection.select_values(Payment.sanitize_sql_array([
        "SELECT nextval(pg_get_serial_sequence('payments', 'id')) FROM generate_series(1, ?)", entries.size
      ])).map(&:to_i).sort

      Payment.insert_all!(entries.zip(ids).map do |entry, id|
        {
          id:,
          bulk_payment_id: bulk_payment.id,
          payer_firm_id: bulk_payment.payer_firm_id,
          payee_firm_id: payee_ids.fetch(entry.payee_uuid),
          amount_cents: entry.amount_cents,
          description: entry.description
        }
      end)
    end

    def apply_balance_changes(payer, credits)
      deltas = credits.merge(payer.id => -@request.total_cents)
      firms = Firm.arel_table
      delta_for_id = deltas.reduce(Arel::Nodes::Case.new(firms[:id])) { |node, (id, delta)| node.when(id).then(delta) }
      Firm.where(id: deltas.keys).update_all(balance_cents: firms[:balance_cents] + delta_for_id)
    end

    def payer_not_found
      Error.new("payer_not_found", "The payer firm does not exist.")
    end
  end
end
