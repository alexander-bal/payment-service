require "rails_helper"

# Runs outside a wrapping transaction so that requests get separate database connections and really contend for
# row locks. A barrier connection holds the locks while the requests pile up behind it, which forces the
# interleavings that would deadlock or double-spend if the locking were wrong.
RSpec.describe "POST /bulk_payments under concurrency", type: :request do
  self.use_transactional_tests = false

  let(:pool) { ActiveRecord::Base.connection_pool }

  def barriers
    @barriers ||= []
  end

  def hold_locks(*firms)
    connection = pool.checkout
    unlocked.delete(connection)
    connection.begin_db_transaction
    connection.execute("SELECT id FROM firms WHERE id IN (#{firms.map(&:id).join(', ')}) ORDER BY id FOR UPDATE")
    barriers << connection
    connection
  end

  # Rolling back frees the locks and is safe from any thread; only the owning thread may check the connection in.
  def unlock(connection)
    connection.rollback_db_transaction if unlocked.add?(connection)
  end

  def release(connection)
    return unless barriers.delete(connection)

    unlock(connection)
    pool.checkin(connection)
  end

  def unlocked
    @unlocked ||= Set.new.compare_by_identity
  end

  def wait_for_blocked_requests(count)
    deadline = Time.current + 10
    loop do
      blocked = ActiveRecord::Base.connection.select_value(<<~SQL).to_i
        SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock'
      SQL
      return if blocked >= count
      raise "only #{blocked} of #{count} requests are waiting on a lock" if Time.current > deadline

      sleep 0.02
    end
  end

  # Each request runs on its own thread, and so its own connection, with its own integration session.
  def concurrently(*requests)
    sessions = requests.map { open_session }
    threads = requests.zip(sessions).map do |(body, key), session|
      Thread.new do
        Thread.current.report_on_exception = false
        headers = { "CONTENT_TYPE" => "application/json", "Idempotency-Key" => key }
        session.post("/bulk_payments", params: body.to_json, headers:)
        session.response
      ensure
        pool.release_connection
      end
    end
    -> { Timeout.timeout(20) { threads.map(&:value) } }
  end

  def payload(from, to, amount)
    bulk_body([ entry(to.uuid, amount) ], payer: from.uuid)
  end

  def lock_wait_ms=(milliseconds)
    Rails.configuration.x.bulk_payments.lock_wait_ms = milliseconds
  end

  # Starts from two fresh firms with 100.00 each. A failing scenario must not leave a barrier holding locks, or the
  # TRUNCATE would wait on it forever.
  def scenario(label)
    default_lock_wait = Rails.configuration.x.bulk_payments.lock_wait_ms
    ActiveRecord::Base.connection.execute("TRUNCATE payments, bulk_payments, firms RESTART IDENTITY CASCADE")
    aggregate_failures(label) do
      yield create(:firm, balance_cents: 10_000), create(:firm, balance_cents: 10_000)
    end
  ensure
    self.lock_wait_ms = default_lock_wait
    barriers.dup.each { |connection| release(connection) }
    ActiveRecord::Base.connection.execute("TRUNCATE payments, bulk_payments, firms RESTART IDENTITY CASCADE")
  end

  it "keeps balances exact and avoids deadlocks under contention", :aggregate_failures do
    Rails.application.eager_load!

    scenario "A to B and B to A at once complete without deadlock" do |low, high|
      barrier = hold_locks(low, high)
      results = concurrently([ payload(low, high, "10.00"), "ab" ], [ payload(high, low, "5.00"), "ba" ])
      wait_for_blocked_requests(2)
      release(barrier)

      responses = results.call

      expect(responses.map(&:status)).to eq([ 201, 201 ])
      expect(low.reload.balance_cents).to eq(10_000 - 1_000 + 500)
      expect(high.reload.balance_cents).to eq(10_000 + 1_000 - 500)
      expect(BulkPayment.count).to eq(2)
    end

    scenario "two requests with the same key settle once and replay the other" do |low, high|
      barrier = hold_locks(low)
      body = payload(low, high, "10.00")
      results = concurrently([ body, "same-key" ], [ body, "same-key" ])
      wait_for_blocked_requests(2)
      release(barrier)

      responses = results.call

      expect(responses.map(&:status)).to eq([ 201, 201 ])
      expect(responses.map { |response| response.headers["Idempotent-Replayed"] }).to contain_exactly(nil, "true")
      expect(responses.map(&:parsed_body).uniq.size).to eq(1)
      expect(BulkPayment.count).to eq(1)
      expect(Payment.count).to eq(1)
      expect(low.reload.balance_cents).to eq(9_000)
      expect(high.reload.balance_cents).to eq(11_000)
    end

    scenario "a racing request reusing the key for a different request is rejected" do |low, high|
      barrier = hold_locks(low)
      results = concurrently([ payload(low, high, "10.00"), "same-key" ], [ payload(low, high, "20.00"), "same-key" ])
      wait_for_blocked_requests(2)
      release(barrier)

      responses = results.call

      expect(responses.map(&:status).sort).to eq([ 201, 409 ])
      expect(responses.map(&:parsed_body).find { |body| body["error"] }.dig("error", "code")).to eq("idempotency_key_reused")
      expect(BulkPayment.count).to eq(1)
      expect(Payment.count).to eq(1)
      expect(Firm.sum(:balance_cents)).to eq(20_000)
    end

    scenario "only one of two individually affordable requests spends the same balance" do |low, high|
      third = create(:firm, balance_cents: 0)
      barrier = hold_locks(low)
      results = concurrently([ payload(low, high, "80.00"), "one" ], [ payload(low, third, "80.00"), "two" ])
      wait_for_blocked_requests(2)
      release(barrier)

      responses = results.call

      expect(responses.map(&:status).sort).to eq([ 201, 422 ])
      expect(responses.map(&:parsed_body).find { |body| body["error"] }.dig("error", "code")).to eq("insufficient_funds")
      expect(BulkPayment.count).to eq(1)
      expect(low.reload.balance_cents).to eq(2_000)
      expect(Firm.sum(:balance_cents)).to eq(20_000)
    end

    scenario "only one of two requests that each fit under a payee's maximum but not together is accepted" do |low, high|
      max = 2_147_483_647
      near_max = create(:firm, balance_cents: max - 100)
      barrier = hold_locks(near_max)
      results = concurrently([ payload(low, near_max, "0.60"), "one" ], [ payload(high, near_max, "0.60"), "two" ])
      wait_for_blocked_requests(2)
      release(barrier)

      responses = results.call

      expect(responses.map(&:status).sort).to eq([ 201, 422 ])
      expect(responses.map(&:parsed_body).find { |body| body["error"] }.dig("error", "code")).to eq("payee_balance_limit_exceeded")
      expect(near_max.reload.balance_cents).to eq(max - 40)
      expect(BulkPayment.count).to eq(1)
      expect(Firm.sum(:balance_cents)).to eq(20_000 + max - 100)
    end

    scenario "a cycle of three firms paying each other completes without deadlock" do |low, high|
      third = create(:firm, balance_cents: 10_000)
      barrier = hold_locks(low, high, third)
      results = concurrently(
        [ payload(low, high, "1.00"), "first" ], [ payload(high, third, "2.00"), "second" ], [ payload(third, low, "3.00"), "third" ]
      )
      wait_for_blocked_requests(3)
      release(barrier)

      responses = results.call

      expect(responses.map(&:status)).to eq([ 201, 201, 201 ])
      expect([ low, high, third ].map { |firm| firm.reload.balance_cents }).to eq([ 10_200, 9_900, 9_900 ])
      expect(BulkPayment.count).to eq(3)
    end

    scenario "requests over disjoint firms run while others wait" do |low, high|
      other_payer = create(:firm, balance_cents: 10_000)
      other_payee = create(:firm, balance_cents: 0)
      barrier = hold_locks(low, high)
      results = concurrently([ payload(low, high, "1.00"), "blocked" ])
      wait_for_blocked_requests(1)

      post_bulk(payload(other_payer, other_payee, "1.00"), key: "free")

      expect(response).to have_http_status(:created)
      expect(other_payee.reload.balance_cents).to eq(100)

      release(barrier)
      expect(results.call.map(&:status)).to eq([ 201 ])
    end

    scenario "unavailable row locks answer 503 busy, leave no partial state and accept a retry once free" do |low, high|
      self.lock_wait_ms = 300
      barrier = hold_locks(high)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      post_bulk(payload(low, high, "10.00"), key: "retry")

      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 5
      expect(response).to have_http_status(:service_unavailable)
      expect(error_body).to include("code" => "busy", "message" => a_kind_of(String))
      expect(BulkPayment.count).to eq(0)
      expect(Payment.count).to eq(0)
      expect(Firm.order(:id).pluck(:balance_cents)).to eq([ 10_000, 10_000 ])

      release(barrier)
      post_bulk(payload(low, high, "10.00"), key: "retry")

      expect(response).to have_http_status(:created)
      expect(response.headers["Idempotent-Replayed"]).to be_nil
      expect(low.reload.balance_cents).to eq(9_000)
    end

    # Rows are locked in id order. Releasing the first row after 0.6s of a 1s bound leaves a per-row bound waiting
    # until about 1.6s on the second row, while a bound on the whole lock set gives up at about 1.0s.
    scenario "the lock wait is bounded for the whole lock set, not for each row" do |low, high|
      self.lock_wait_ms = 1_000
      first = hold_locks(low)
      second = hold_locks(high)
      releaser = Thread.new do
        sleep 0.6
        unlock(first)
      end

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      post_bulk(bulk_body([ entry(high.uuid, "1.00") ], payer: low.uuid))
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      releaser.join
      release(first)
      release(second)

      expect(response).to have_http_status(:service_unavailable)
      expect(elapsed).to be_between(0.9, 1.3)
    end
  end
end
