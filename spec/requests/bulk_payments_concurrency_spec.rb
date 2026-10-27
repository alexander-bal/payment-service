require "rails_helper"

# Runs outside a wrapping transaction so that requests get separate database connections and really contend for
# row locks. A barrier connection holds the locks while the requests pile up behind it, which forces the
# interleavings that would deadlock or double-spend if the locking were wrong.
RSpec.describe "POST /bulk_payments under concurrency", type: :request do
  self.use_transactional_tests = false

  let(:pool) { ActiveRecord::Base.connection_pool }
  let!(:low) { create(:firm, balance_cents: 10_000) }
  let!(:high) { create(:firm, balance_cents: 10_000) }

  before(:all) { Rails.application.eager_load! }

  # A failing example must not leave a barrier holding locks, or the TRUNCATE below would wait on it forever.
  after do
    barriers.each { |connection| release(connection) }
    ActiveRecord::Base.connection.execute("TRUNCATE payments, bulk_payments, firms RESTART IDENTITY CASCADE")
  end

  def barriers
    @barriers ||= []
  end

  def hold_locks(*firms)
    connection = pool.checkout
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
    [ threads, -> { Timeout.timeout(20) { threads.map(&:value) } } ]
  end

  def payload(from, to, amount)
    bulk_body([ entry(to.uuid, amount) ], payer: from.uuid)
  end

  it "runs A to B and B to A at once without deadlock" do
    barrier = hold_locks(low, high)
    _threads, results = concurrently([ payload(low, high, "10.00"), "ab" ], [ payload(high, low, "5.00"), "ba" ])
    wait_for_blocked_requests(2)
    release(barrier)

    responses = results.call

    expect(responses.map(&:status)).to eq([ 201, 201 ])
    expect(low.reload.balance_cents).to eq(10_000 - 1_000 + 500)
    expect(high.reload.balance_cents).to eq(10_000 + 1_000 - 500)
    expect(BulkPayment.count).to eq(2)
  end

  it "settles two requests with the same key once and replays the other" do
    barrier = hold_locks(low)
    body = payload(low, high, "10.00")
    _threads, results = concurrently([ body, "same-key" ], [ body, "same-key" ])
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

  it "rejects a racing request that reuses a key for a different request" do
    barrier = hold_locks(low)
    _threads, results = concurrently([ payload(low, high, "10.00"), "same-key" ], [ payload(low, high, "20.00"), "same-key" ])
    wait_for_blocked_requests(2)
    release(barrier)

    responses = results.call

    expect(responses.map(&:status).sort).to eq([ 201, 409 ])
    expect(responses.map(&:parsed_body).find { |body| body["error"] }.dig("error", "code")).to eq("idempotency_key_reused")
    expect(BulkPayment.count).to eq(1)
    expect(Payment.count).to eq(1)
    expect(Firm.sum(:balance_cents)).to eq(20_000)
  end

  it "lets only one of two individually affordable requests spend the same balance" do
    third = create(:firm, balance_cents: 0)
    barrier = hold_locks(low)
    _threads, results = concurrently([ payload(low, high, "80.00"), "one" ], [ payload(low, third, "80.00"), "two" ])
    wait_for_blocked_requests(2)
    release(barrier)

    responses = results.call

    expect(responses.map(&:status).sort).to eq([ 201, 422 ])
    expect(responses.map(&:parsed_body).find { |body| body["error"] }.dig("error", "code")).to eq("insufficient_funds")
    expect(BulkPayment.count).to eq(1)
    expect(low.reload.balance_cents).to eq(2_000)
    expect(Firm.sum(:balance_cents)).to eq(20_000)
  end

  it "runs requests over disjoint firms while others wait" do
    other_payer = create(:firm, balance_cents: 10_000)
    other_payee = create(:firm, balance_cents: 0)
    barrier = hold_locks(low, high)
    _threads, results = concurrently([ payload(low, high, "1.00"), "blocked" ])
    wait_for_blocked_requests(1)

    post_bulk(payload(other_payer, other_payee, "1.00"), key: "free")

    expect(response).to have_http_status(:created)
    expect(other_payee.reload.balance_cents).to eq(100)

    release(barrier)
    expect(results.call.map(&:status)).to eq([ 201 ])
  end

  describe "when the row locks cannot be acquired in time" do
    around do |example|
      configuration = Rails.configuration.x.bulk_payments
      original = configuration.lock_wait_ms
      configuration.lock_wait_ms = 300
      example.run
    ensure
      configuration.lock_wait_ms = original
    end

    it "answers 503 busy, leaves no partial state, and accepts a retry once the locks are free" do
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
    it "bounds the wait for the whole lock set, not for each row" do
      Rails.configuration.x.bulk_payments.lock_wait_ms = 1_000
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
