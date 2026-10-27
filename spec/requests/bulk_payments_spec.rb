require "rails_helper"

RSpec.describe "POST /bulk_payments", type: :request do
  def error_fields
    error_body.dig("details", "errors").map { |error| [ error["index"], error["field"] ] }
  end

  def expect_nothing_changed
    expect(BulkPayment.count).to eq(0)
    expect(Payment.count).to eq(0)
    expect(balances.slice(PINECREST, LOPEZ, NAIR)).to eq(PINECREST => 5_000_000, LOPEZ => 50_000, NAIR => 200_000)
  end

  def fail_on(table, event)
    ActiveRecord::Base.connection.execute(<<~SQL)
      CREATE FUNCTION fail_#{table}_#{event}() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN RAISE EXCEPTION 'forced failure'; END $$;
      CREATE TRIGGER fail_#{table}_#{event} BEFORE #{event} ON #{table}
        FOR EACH ROW EXECUTE FUNCTION fail_#{table}_#{event}();
    SQL
  end

  def reported_errors
    reports = []
    subscriber = Object.new
    subscriber.define_singleton_method(:report) { |error, **options| reports << [ error, options ] }
    Rails.error.subscribe(subscriber)
    yield
    reports
  ensure
    Rails.error.unsubscribe(subscriber)
  end

  def expect_invalid(fields)
    expect(response).to have_http_status(:bad_request)
    expect(error_body["code"]).to eq("invalid_request")
    expect(error_fields).to eq(fields)
  end

  it "implements the whole bulk payments contract", :aggregate_failures do
    seed_brief_firms
    max = 2_147_483_647
    valid_entry = entry(LOPEZ, "1")

    scenario "AC-1: the brief's sample request" do
      post_bulk(
        bulk_body([
          entry(NAIR, "6250", "Overflow returns, August 2026"),
          entry(NAIR, "5800.5", "Amended returns, August 2026"),
          entry(LOPEZ, "1200.75", "Bookkeeping cleanup, 3 clients")
        ]),
        key: "brief-sample-1"
      )

      bulk = BulkPayment.sole
      expect(response).to have_http_status(:created)
      expect(response.headers["Idempotent-Replayed"]).to be_nil
      expect(response.parsed_body).to match(
        "id" => bulk.id,
        "payer_firm_uuid" => PINECREST,
        "total_amount" => "13251.25",
        "payments" => [
          { "id" => an_instance_of(Integer), "payee_firm_uuid" => NAIR, "amount" => "6250.00", "description" => "Overflow returns, August 2026" },
          { "id" => an_instance_of(Integer), "payee_firm_uuid" => NAIR, "amount" => "5800.50", "description" => "Amended returns, August 2026" },
          { "id" => an_instance_of(Integer), "payee_firm_uuid" => LOPEZ, "amount" => "1200.75", "description" => "Bookkeeping cleanup, 3 clients" }
        ]
      )

      expect(balances).to eq(PINECREST => 3_674_875, LOPEZ => 170_075, NAIR => 1_405_050)
      expect(balances.values.sum).to eq(5_250_000)

      expect(bulk).to have_attributes(payer_firm_id: 1, idempotency_key: "brief-sample-1", total_amount_cents: 1_325_125)
      payments = Payment.where(bulk_payment_id: bulk.id).order(:id)
      expect(payments.pluck(:payee_firm_id, :amount_cents, :description)).to eq([
        [ 3, 625_000, "Overflow returns, August 2026" ],
        [ 3, 580_050, "Amended returns, August 2026" ],
        [ 2, 120_075, "Bookkeeping cleanup, 3 clients" ]
      ])
      expect(payments.pluck(:payer_firm_id).uniq).to eq([ 1 ])
      expect(Payment.count).to eq(3)
    end

    scenario "FR-2: payment ids ascend in request order and match the response" do
      payees = create_list(:firm, 5, balance_cents: 0)
      post_bulk(bulk_body(payees.zip(%w[5 4 3 2 1]).map { |firm, amount| entry(firm.uuid, amount, "To #{firm.name}") }))

      stored = Payment.order(:id).pluck(:id, :payee_firm_id)
      expect(stored.map(&:last)).to eq(payees.map(&:id))
      expect(response.parsed_body["payments"].map { |payment| payment["id"] }).to eq(stored.map(&:first))
      expect(stored.map(&:first)).to eq(stored.map(&:first).sort)
    end

    scenario "FR-2: entries to the same payee are not merged" do
      post_bulk(bulk_body([ entry(LOPEZ, "1"), entry(LOPEZ, "1"), entry(LOPEZ, "1") ]))

      expect(Payment.where(payee_firm_id: 2).pluck(:amount_cents)).to eq([ 100, 100, 100 ])
    end

    scenario "FR-2: accepted rows are immutable" do
      post_bulk(bulk_body([ entry(LOPEZ, "1") ]))

      expect { BulkPayment.sole.update!(total_amount_cents: 1) }.to raise_error(ActiveRecord::ReadOnlyRecord)
      expect { BulkPayment.sole.destroy! }.to raise_error(ActiveRecord::ReadOnlyRecord)
      expect { Payment.sole.update!(amount_cents: 1) }.to raise_error(ActiveRecord::ReadOnlyRecord)
      expect { Payment.sole.destroy! }.to raise_error(ActiveRecord::ReadOnlyRecord)
    end

    scenario "FR-3: fields beyond the documented ones are ignored" do
      body = bulk_body([ entry(LOPEZ, "1").merge("note" => "x", "amount_cents" => 99_999) ]).merge("extra" => { "a" => 1 })
      post_bulk(body)

      expect(response).to have_http_status(:created)
      expect(Payment.sole.amount_cents).to eq(100)
    end

    scenario "FR-3: the body is read as JSON whatever the content type claims" do
      raw = bulk_body([ entry(LOPEZ, "1", "100% sure") ]).to_json
      [ "text/plain", "application/x-www-form-urlencoded", "multipart/form-data", "" ].each_with_index do |content_type, index|
        aggregate_failures("content type #{content_type.inspect}") do
          post "/bulk_payments", params: raw, headers: { "CONTENT_TYPE" => content_type, "Idempotency-Key" => "type-#{index}" }

          expect(response).to have_http_status(:created)
          expect(response.parsed_body["payments"].first).to include("description" => "100% sure")
        end
      end
      expect(Payment.pluck(:description)).to eq([ "100% sure" ] * 4)

      post "/bulk_payments", params: "payer_firm_uuid=#{PINECREST}&note=100%zz",
        headers: { "CONTENT_TYPE" => "application/x-www-form-urlencoded", "Idempotency-Key" => "form" }

      expect(response).to have_http_status(:bad_request)
      expect(response.media_type).to eq("application/json")
      expect(error_body["code"]).to eq("invalid_request")
    end

    scenario "FR-4: a malformed query string gets the documented error object" do
      [ "x=%", "x=%FF" ].each do |query|
        aggregate_failures("query #{query}") do
          post "/bulk_payments?#{query}", params: bulk_body([ valid_entry ]).to_json,
            headers: { "CONTENT_TYPE" => "application/json", "Idempotency-Key" => "query" }

          expect(response).to have_http_status(:bad_request)
          expect(response.media_type).to eq("application/json")
          expect(error_body["code"]).to eq("invalid_request")
          expect_nothing_changed
        end
      end
    end

    scenario "FR-3: only POST /bulk_payments is exposed" do
      [ [ :get, "/bulk_payments" ], [ :get, "/bulk_payments/1" ], [ :put, "/bulk_payments" ], [ :patch, "/bulk_payments/1" ],
        [ :delete, "/bulk_payments/1" ], [ :get, "/payments" ], [ :get, "/firms" ] ].each do |verb, path|
        aggregate_failures("#{verb.upcase} #{path}") do
          public_send(verb, path)

          expect(response).to have_http_status(:not_found)
        end
      end
    end

    scenario "FR-4: a missing Idempotency-Key is rejected" do
      post_bulk(bulk_body([ valid_entry ]), key: nil)

      expect_invalid([ [ nil, "Idempotency-Key" ] ])
      expect_nothing_changed
    end

    scenario "FR-4: malformed Idempotency-Keys are rejected" do
      [ "", "a" * 256, "café", "tab\tkey" ].each do |key|
        aggregate_failures("key #{key.inspect[0, 20]}") do
          post_bulk(bulk_body([ valid_entry ]), key:)

          expect_invalid([ [ nil, "Idempotency-Key" ] ])
          expect_nothing_changed
        end
      end
    end

    scenario "FR-4: keys of 1 and 255 printable ASCII characters are accepted" do
      post_bulk(bulk_body([ valid_entry ]), key: "a")
      post_bulk(bulk_body([ entry(LOPEZ, "2") ]), key: "~ #{'!' * 251} ~")
      post_bulk(bulk_body([ entry(LOPEZ, "3") ]), key: "z" * 255)

      expect(BulkPayment.count).to eq(3)
    end

    scenario "FR-4: bodies that are not a JSON object are rejected" do
      [ "", "not json", "{", "[]", "\"text\"", "42", "null", "[{}]" ].each do |raw|
        aggregate_failures("body #{raw.inspect}") do
          post_bulk(raw)

          expect(response).to have_http_status(:bad_request)
          expect(error_body["code"]).to eq("invalid_request")
          expect_nothing_changed
        end
      end
    end

    scenario "FR-4: a body that is not valid UTF-8 gets the documented error object" do
      post_bulk("{\"payer_firm_uuid\":\"\xFF\"}".b)

      expect(response).to have_http_status(:bad_request)
      expect(response.media_type).to eq("application/json")
      expect(error_body["code"]).to eq("invalid_request")
    end

    scenario "FR-4: descriptions that are not valid UTF-8 are rejected" do
      head = %({"payer_firm_uuid":"#{PINECREST}","payments":[{"amount":"1","payee_firm_uuid":"#{LOPEZ}","description":)
      [ %("a\\ud800b"), %("a\xFFb").b ].each do |description|
        aggregate_failures("description #{description.inspect}") do
          post_bulk("#{head.b}#{description}}]}".b)

          expect(response).to have_http_status(:bad_request)
          expect(response.media_type).to eq("application/json")
          expect(error_body["code"]).to eq("invalid_request")
          expect_nothing_changed
        end
      end
    end

    scenario "FR-4: extremely nested JSON is rejected, not crashed on" do
      post_bulk(%({"payer_firm_uuid":#{'[' * 5_000}#{']' * 5_000}}))

      expect(response).to have_http_status(:bad_request)
      expect(error_body["code"]).to eq("invalid_request")
      expect_nothing_changed
    end

    scenario "FR-4: a bad key and a bad body are reported together" do
      post_bulk({}, key: "")

      expect(error_fields).to contain_exactly([ nil, "Idempotency-Key" ], [ nil, "payer_firm_uuid" ], [ nil, "payments" ])
    end

    scenario "FR-4: missing and mistyped fields are reported with their index" do
      post_bulk({})
      expect(error_fields).to contain_exactly([ nil, "payer_firm_uuid" ], [ nil, "payments" ])

      post_bulk({ "payer_firm_uuid" => 5, "payments" => { "0" => {} } })
      expect(error_fields).to contain_exactly([ nil, "payer_firm_uuid" ], [ nil, "payments" ])

      post_bulk(bulk_body([ valid_entry, "nope", {}, { "amount" => 5, "payee_firm_uuid" => 7, "description" => [] } ]))
      expect(error_fields).to contain_exactly(
        [ 1, "payments" ],
        [ 2, "payee_firm_uuid" ], [ 2, "amount" ], [ 2, "description" ],
        [ 3, "payee_firm_uuid" ], [ 3, "amount" ], [ 3, "description" ]
      )
      expect_nothing_changed
    end

    scenario "FR-4: malformed uuids are reported per index" do
      post_bulk(bulk_body([ entry("nope", "1"), valid_entry, entry(LOPEZ.delete("-"), "1"), entry("#{LOPEZ}0", "1") ],
        payer: "not-a-uuid"))

      expect(response).to have_http_status(:bad_request)
      expect(error_fields).to contain_exactly(
        [ nil, "payer_firm_uuid" ], [ 0, "payee_firm_uuid" ], [ 2, "payee_firm_uuid" ], [ 3, "payee_firm_uuid" ]
      )
      expect_nothing_changed
    end

    scenario "FR-4: a payee equal to the payer is rejected, even in a different letter case" do
      post_bulk(bulk_body([ valid_entry, entry(PINECREST.upcase, "1") ]))

      expect_invalid([ [ 1, "payee_firm_uuid" ] ])
      expect_nothing_changed
    end

    scenario "FR-4: uuids match case-insensitively" do
      post_bulk(bulk_body([ entry(LOPEZ.upcase, "1") ], payer: PINECREST.upcase))

      expect(response).to have_http_status(:created)
      expect(response.parsed_body).to include("payer_firm_uuid" => PINECREST)
      expect(response.parsed_body["payments"].first).to include("payee_firm_uuid" => LOPEZ)
    end

    scenario "FR-4: the payments array holds between 1 and 1,000 entries" do
      post_bulk(bulk_body([]))
      expect_invalid([ [ nil, "payments" ] ])

      post_bulk(bulk_body(Array.new(1_001) { valid_entry }))
      expect_invalid([ [ nil, "payments" ] ])
      expect_nothing_changed

      post_bulk(bulk_body(Array.new(1_000) { valid_entry }), key: "thousand")
      expect(response).to have_http_status(:created)
      expect(Payment.count).to eq(1_000)
    end

    scenario "FR-4: amounts that are not plain dollar strings are rejected" do
      [ "1e3", "-1", "+1", " 1", "1 ", "1,000", "1.", ".5", "1.005", "abc", "", "１２", "1\n", "0x10", "1_000", "1.5.0",
        "$1", "1e-2", "NaN", "Infinity" ].each do |amount|
        aggregate_failures("string #{amount.inspect}") do
          post_bulk(bulk_body([ valid_entry, entry(LOPEZ, amount) ]))

          expect(response).to have_http_status(:bad_request)
          expect(error_fields).to eq([ [ 1, "amount" ] ])
          expect_nothing_changed
        end
      end

      [ 100, 1.5, true, [], {} ].each do |amount|
        aggregate_failures("JSON #{amount.class} #{amount.inspect}") do
          post_bulk(bulk_body([ entry(LOPEZ, amount) ]))

          expect(response).to have_http_status(:bad_request)
          expect(error_fields).to eq([ [ 0, "amount" ] ])
        end
      end

      post_bulk(bulk_body([ entry(LOPEZ, nil), { "payee_firm_uuid" => LOPEZ, "description" => "x" } ]))
      expect(error_fields).to eq([ [ 0, "amount" ], [ 1, "amount" ] ])

      expect_nothing_changed
    end

    scenario "FR-4: amounts outside $0.01 to $21,474,836.47 are rejected" do
      %w[0 0.0 0.00 000 21474836.48 21474837 99999999999 99999999999999999999999999999999999999].each do |amount|
        aggregate_failures("amount #{amount}") do
          post_bulk(bulk_body([ entry(LOPEZ, amount) ]))

          expect(response).to have_http_status(:bad_request)
          expect(error_fields).to eq([ [ 0, "amount" ] ])
        end
      end

      post_bulk(bulk_body([ entry(LOPEZ, "9" * 10_000) ]))
      expect(response).to have_http_status(:bad_request)
      expect(error_fields).to eq([ [ 0, "amount" ] ])

      expect_nothing_changed
    end

    scenario "FR-4: leading zeros and one or two decimals are accepted" do
      post_bulk(bulk_body([ entry(LOPEZ, "007"), entry(LOPEZ, "0.5"), entry(LOPEZ, "0.05"), entry(LOPEZ, "00000000000000000001.10") ]))

      expect(response).to have_http_status(:created)
      expect(Payment.order(:id).pluck(:amount_cents)).to eq([ 700, 50, 5, 110 ])
    end

    scenario "FR-4: a total above $21,474,836.47 is rejected though every amount is valid" do
      post_bulk(bulk_body([ entry(LOPEZ, "21474836.47"), entry(NAIR, "0.01") ]))
      expect_invalid([ [ nil, "payments" ] ])
      expect_nothing_changed

      post_bulk(bulk_body(Array.new(300) { entry(LOPEZ, "100000") }))
      expect_invalid([ [ nil, "payments" ] ])
      expect_nothing_changed
    end

    scenario "FR-4: blank descriptions, NUL characters and overlong descriptions are rejected" do
      [ "", " ", "  \t\n ", " ", "　" ].each do |description|
        aggregate_failures("description #{description.inspect}") do
          post_bulk(bulk_body([ entry(LOPEZ, "1", description) ]))

          expect(response).to have_http_status(:bad_request)
          expect(error_fields).to eq([ [ 0, "description" ] ])
        end
      end

      post_bulk(bulk_body([ entry(LOPEZ, "1", "a\u0000b") ]))
      expect_invalid([ [ 0, "description" ] ])

      post_bulk(bulk_body([ entry(LOPEZ, "1", "é" * 256) ]))
      expect_invalid([ [ 0, "description" ] ])

      expect_nothing_changed
    end

    scenario "FR-4: 255 characters are accepted, counted as characters rather than bytes" do
      post_bulk(bulk_body([ entry(LOPEZ, "1", "é" * 255), entry(LOPEZ, "1", "日本語 🎉") ]), key: "ok")

      expect(response).to have_http_status(:created)
      expect(Payment.order(:id).pluck(:description)).to eq([ "é" * 255, "日本語 🎉" ])
    end

    scenario "FR-4: descriptions are stored verbatim, including surrounding whitespace" do
      post_bulk(bulk_body([ entry(LOPEZ, "1", "  padded  ") ]))

      expect(Payment.sole.description).to eq("  padded  ")
    end

    scenario "FR-4: every offending entry is reported, not only the first" do
      post_bulk(bulk_body([
        valid_entry,
        entry(LOPEZ, "1.234"),
        entry("bad", "2", " "),
        entry(PINECREST, "3"),
        entry(NAIR, "0"),
        valid_entry
      ]))

      expect(response).to have_http_status(:bad_request)
      expect(error_fields).to contain_exactly(
        [ 1, "amount" ], [ 2, "payee_firm_uuid" ], [ 2, "description" ], [ 3, "payee_firm_uuid" ], [ 4, "amount" ]
      )
      expect(error_body["details"]["errors"]).to all(include("message" => a_kind_of(String)))
      expect_nothing_changed
    end

    scenario "FR-5: an unknown payer answers 404" do
      post_bulk(bulk_body([ entry(LOPEZ, "1") ], payer: UNKNOWN))

      expect(response).to have_http_status(:not_found)
      expect(error_body).to include("code" => "payer_not_found", "message" => a_kind_of(String))
      expect(error_body).not_to have_key("details")
      expect_nothing_changed
    end

    scenario "FR-5: unknown payees deny the whole request with 422 listing each distinct one" do
      other = "11111111-1111-4111-8111-111111111111"
      post_bulk(bulk_body([ entry(LOPEZ, "1"), entry(UNKNOWN, "1"), entry(other, "1"), entry(UNKNOWN, "1") ]))

      expect(response).to have_http_status(:unprocessable_content)
      expect(error_body["code"]).to eq("payee_not_found")
      expect(error_body["details"]).to eq("unknown_payee_firm_uuids" => [ UNKNOWN, other ])
      expect_nothing_changed
    end

    scenario "FR-5: 404 is answered before 422 when the payer and a payee are both unknown" do
      post_bulk(bulk_body([ entry(UNKNOWN, "1") ], payer: "22222222-2222-4222-8222-222222222222"))

      expect(response).to have_http_status(:not_found)
    end

    scenario "FR-6: a request that spends the balance to exactly zero is accepted" do
      post_bulk(bulk_body([ entry(NAIR, "500.00") ], payer: LOPEZ))

      expect(response).to have_http_status(:created)
      expect(balances).to include(LOPEZ => 0, NAIR => 250_000)
    end

    scenario "FR-6: a request one cent over the balance is denied without a trace or a balance leak" do
      post_bulk(bulk_body([ entry(NAIR, "500.01") ], payer: LOPEZ))

      expect(response).to have_http_status(:unprocessable_content)
      expect(error_body["code"]).to eq("insufficient_funds")
      expect(error_body["details"]).to eq("required_total" => "500.01")
      expect(response.body).not_to match(/50000|500\.00|balance_cents/)
      expect_nothing_changed
    end

    scenario "FR-6: the funds check covers the sum of all entries" do
      post_bulk(bulk_body([ entry(NAIR, "300"), entry(PINECREST, "200.01") ], payer: LOPEZ))

      expect(response).to have_http_status(:unprocessable_content)
      expect(error_body["code"]).to eq("insufficient_funds")
      expect_nothing_changed
    end

    scenario "FR-6: a credit landing exactly on the maximum balance is accepted" do
      near_max = create(:firm, balance_cents: max - 100)
      post_bulk(bulk_body([ entry(near_max.uuid, "1.00") ]))

      expect(response).to have_http_status(:created)
      expect(near_max.reload.balance_cents).to eq(max)
    end

    scenario "FR-6: a credit one cent over the maximum is denied and lists the payee" do
      near_max = create(:firm, balance_cents: max - 100)
      post_bulk(bulk_body([ entry(LOPEZ, "5"), entry(near_max.uuid, "1.01") ]))

      expect(response).to have_http_status(:unprocessable_content)
      expect(error_body["code"]).to eq("payee_balance_limit_exceeded")
      expect(error_body["details"]).to eq("payee_firm_uuids" => [ near_max.uuid ])
      expect(near_max.reload.balance_cents).to eq(max - 100)
      expect_nothing_changed
    end

    scenario "FR-6: entries to one payee are summed before the maximum is checked" do
      near_max = create(:firm, balance_cents: max - 100)
      post_bulk(bulk_body([ entry(near_max.uuid, "0.60"), entry(near_max.uuid, "0.60") ]))

      expect(response).to have_http_status(:unprocessable_content)
      expect(error_body["details"]).to eq("payee_firm_uuids" => [ near_max.uuid ])
      expect(near_max.reload.balance_cents).to eq(max - 100)
    end

    scenario "FR-6: every payee over the maximum is listed" do
      near_max = create(:firm, balance_cents: max - 100)
      full = create(:firm, balance_cents: max)
      post_bulk(bulk_body([ entry(near_max.uuid, "2"), entry(full.uuid, "0.01") ]))

      expect(error_body["details"]["payee_firm_uuids"]).to contain_exactly(near_max.uuid, full.uuid)
    end

    scenario "FR-6: insufficient funds is reported before payee limits" do
      near_max = create(:firm, balance_cents: max - 100)
      post_bulk(bulk_body([ entry(near_max.uuid, "600") ], payer: LOPEZ))

      expect(error_body["code"]).to eq("insufficient_funds")
    end

    scenario "FR-6: a full-range amount moves without 32-bit overflow" do
      rich = create(:firm, balance_cents: max)
      poor = create(:firm, balance_cents: 0)
      post_bulk(bulk_body([ entry(poor.uuid, "21474836.47") ], payer: rich.uuid))

      expect(response).to have_http_status(:created)
      expect(rich.reload.balance_cents).to eq(0)
      expect(poor.reload.balance_cents).to eq(max)
    end

    scenario "FR-6: the sum of all balances is unchanged" do
      before_total = Firm.sum(:balance_cents)
      post_bulk(bulk_body([ entry(NAIR, "10.10"), entry(LOPEZ, "0.01"), entry(NAIR, "99.99") ]))

      expect(Firm.sum(:balance_cents)).to eq(before_total)
    end

    # Each of these is a classic Float trap: 4.35 * 100 == 434.99999999999994 and so on.
    {
      "4.35" => 435, "1.15" => 115, "8.2" => 820, "0.29" => 29, "0.57" => 57, "1.1" => 110, "19.99" => 1_999,
      "0.1" => 10, "0.7" => 70, "33.33" => 3_333, "12345.67" => 1_234_567
    }.each do |amount, cents|
      scenario "cents: #{amount} converts to #{cents}" do
        post_bulk(bulk_body([ entry(LOPEZ, amount) ]))

        expect(Payment.sole.amount_cents).to eq(cents)
        expect(response.parsed_body["total_amount"]).to eq(format("%d.%02d", cents / 100, cents % 100))
        expect(balances[LOPEZ]).to eq(50_000 + cents)
      end
    end

    scenario "cents: 0.1 and 0.2 sum to exactly 0.30" do
      post_bulk(bulk_body([ entry(LOPEZ, "0.1"), entry(LOPEZ, "0.2") ]))

      expect(response.parsed_body["total_amount"]).to eq("0.30")
      expect(BulkPayment.sole.total_amount_cents).to eq(30)
      expect(balances).to include(LOPEZ => 50_030, PINECREST => 4_999_970)
    end

    scenario "cents: a thousand one-cent entries sum to exactly ten dollars" do
      post_bulk(bulk_body(Array.new(1_000) { entry(LOPEZ, "0.01") }))

      expect(response.parsed_body["total_amount"]).to eq("10.00")
      expect(balances).to include(LOPEZ => 51_000, PINECREST => 4_999_000)
    end

    scenario "cents: many awkward amounts sum to the exact total" do
      amounts = %w[19.99 19.99 19.99 0.07 0.07 0.07 33.33 33.34 0.29 0.58 1.15 4.35]
      post_bulk(bulk_body(amounts.map { |amount| entry(NAIR, amount) }))

      expected = amounts.sum { |amount| amount.delete(".").to_i * (amount.include?(".") ? 10**(2 - amount.split(".").last.size) : 100) }
      expect(BulkPayment.sole.total_amount_cents).to eq(expected)
      expect(balances[NAIR]).to eq(200_000 + expected)
      expect(balances[PINECREST]).to eq(5_000_000 - expected)
    end

    { "payments" => "INSERT", "firms" => "UPDATE" }.each do |table, event|
      scenario "FR-6: a write failing on #{event} #{table} leaves no bulk payment, payments or balance change" do
        fail_on(table, event)

        reports = reported_errors { post_bulk(bulk_body([ entry(NAIR, "10"), entry(LOPEZ, "10") ])) }

        expect(response).to have_http_status(:internal_server_error)
        expect(error_body).to include("code" => "internal_error", "message" => a_kind_of(String))
        expect(response.body).not_to include("forced failure")
        expect(reports.map { |error, _| error.message }).to match([ /forced failure/ ])
        expect(reports.map { |_, options| options[:handled] }).to eq([ true ])
        expect_nothing_changed
      end
    end

    scenario "NFR-1: the lock wait bound defaults to 5 seconds" do
      expect(Rails.configuration.x.bulk_payments.lock_wait_ms).to eq(5_000)
    end

    scenario "NFR-1: the lock wait bound does not limit the writes that follow the locks" do
      default_lock_wait = Rails.configuration.x.bulk_payments.lock_wait_ms
      Rails.configuration.x.bulk_payments.lock_wait_ms = 100
      ActiveRecord::Base.connection.execute(<<~SQL)
        CREATE FUNCTION slow_payment_insert() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN PERFORM pg_sleep(0.3); RETURN NEW; END $$;
        CREATE TRIGGER slow_payment_insert BEFORE INSERT ON payments
          FOR EACH ROW EXECUTE FUNCTION slow_payment_insert();
      SQL

      post_bulk(bulk_body([ valid_entry ]))

      expect(response).to have_http_status(:created)
      expect(Payment.count).to eq(1)
    ensure
      Rails.configuration.x.bulk_payments.lock_wait_ms = default_lock_wait
    end

    scenario "FR-7: amounts render as dollar strings with exactly two decimals" do
      post_bulk(bulk_body([ entry(NAIR, "300"), entry(NAIR, "0.5"), entry(NAIR, "12.3"), entry(NAIR, "10000") ]))

      expect(response.parsed_body["payments"].map { |payment| payment["amount"] }).to eq(%w[300.00 0.50 12.30 10000.00])
      expect(response.parsed_body["total_amount"]).to eq("10312.80")
    end

    scenario "FR-7: the success and error bodies carry exactly the documented keys" do
      post_bulk(bulk_body([ entry(NAIR, "1") ]))

      expect(response.media_type).to eq("application/json")
      expect(response.parsed_body.keys).to contain_exactly("id", "payer_firm_uuid", "total_amount", "payments")
      expect(response.parsed_body["payments"].first.keys).to contain_exactly("id", "payee_firm_uuid", "amount", "description")

      post_bulk(bulk_body([ entry(NAIR, "1") ], payer: UNKNOWN), key: "other")

      expect(response.media_type).to eq("application/json")
      expect(error_body.keys).to include("code", "message")
    end

    request_body = bulk_body([ entry(NAIR, "300"), entry(LOPEZ, "12.5", "Cleanup") ])
    after_original = { PINECREST => 4_968_750, LOPEZ => 51_250, NAIR => 230_000 }

    scenario "FR-8: the key and a fingerprint are stored on the bulk payment" do
      post_bulk(request_body, key: "retry-1")

      expect(BulkPayment.sole).to have_attributes(idempotency_key: "retry-1", request_fingerprint: match(/\A\h{64}\z/))
    end

    scenario "FR-8: the same request replays with 201 and Idempotent-Replayed, without settling again" do
      post_bulk(request_body, key: "retry-1")
      original = response.parsed_body

      post_bulk(request_body, key: "retry-1")

      expect(response).to have_http_status(:created)
      expect(response.headers["Idempotent-Replayed"]).to eq("true")
      expect(response.parsed_body).to eq(original)
      expect(BulkPayment.count).to eq(1)
      expect(Payment.count).to eq(2)
      expect(balances).to eq(after_original)
    end

    scenario "FR-8: a replay ignores current balances" do
      post_bulk(request_body, key: "retry-1")
      original = response.parsed_body
      Firm.where(uuid: PINECREST).update_all(balance_cents: 0)

      post_bulk(request_body, key: "retry-1")

      expect(response).to have_http_status(:created)
      expect(response.headers["Idempotent-Replayed"]).to eq("true")
      expect(response.parsed_body).to eq(original)
      expect(balances[PINECREST]).to eq(0)
    end

    scenario "FR-8: a request differing only in formatting replays" do
      post_bulk(request_body, key: "retry-1")
      original = response.parsed_body
      variants = [
        %({"payments":[{"description":"Invoice","payee_firm_uuid":"#{NAIR.upcase}","amount":"300.00"},
                       {"description":"Cleanup","payee_firm_uuid":"#{LOPEZ}","amount":"12.50"}],
           "payer_firm_uuid":"#{PINECREST}"}),
        %(  { "payer_firm_uuid" : "#{PINECREST.upcase}" , "ignored": true, "payments" : [
            { "amount" : "0300", "payee_firm_uuid" : "#{NAIR}", "description" : "Invoice" },
            { "amount" : "12.5", "payee_firm_uuid" : "#{LOPEZ}", "description" : "Cleanup" } ] }  \n)
      ]

      variants.each_with_index do |raw, index|
        aggregate_failures("variant #{index}") do
          post_bulk(raw, key: "retry-1")

          expect(response).to have_http_status(:created)
          expect(response.headers["Idempotent-Replayed"]).to eq("true")
          expect(response.parsed_body).to eq(original)
        end
      end
      expect(BulkPayment.count).to eq(1)
    end

    {
      "another amount" => bulk_body([ entry(NAIR, "300.01"), entry(LOPEZ, "12.5", "Cleanup") ]),
      "another description" => bulk_body([ entry(NAIR, "300"), entry(LOPEZ, "12.5", "cleanup") ]),
      "trailing whitespace in a description" => bulk_body([ entry(NAIR, "300"), entry(LOPEZ, "12.5", "Cleanup ") ]),
      "the same total split differently" => bulk_body([ entry(NAIR, "150"), entry(NAIR, "150"), entry(LOPEZ, "12.5", "Cleanup") ]),
      "another payee" => bulk_body([ entry(LOPEZ, "300"), entry(LOPEZ, "12.5", "Cleanup") ]),
      "another order" => bulk_body([ entry(LOPEZ, "12.5", "Cleanup"), entry(NAIR, "300") ]),
      "an extra entry" => bulk_body([ entry(NAIR, "300"), entry(LOPEZ, "12.5", "Cleanup"), entry(NAIR, "1") ])
    }.each do |difference, different_body|
      scenario "FR-8: a key reused with #{difference} answers 409 and changes nothing" do
        post_bulk(request_body, key: "retry-1")

        post_bulk(different_body, key: "retry-1")

        expect(response).to have_http_status(:conflict)
        expect(error_body).to include("code" => "idempotency_key_reused")
        expect(BulkPayment.count).to eq(1)
        expect(Payment.count).to eq(2)
        expect(balances).to eq(after_original)
      end
    end

    scenario "FR-8: a reused key answers 409 before 422 even when the new request would be denied" do
      post_bulk(request_body, key: "retry-1")

      post_bulk(bulk_body([ entry(UNKNOWN, "1") ]), key: "retry-1")

      expect(response).to have_http_status(:conflict)
    end

    scenario "FR-8: a retry is evaluated afresh after a 422" do
      post_bulk(bulk_body([ entry(NAIR, "600") ], payer: LOPEZ), key: "retry-2")
      expect(response).to have_http_status(:unprocessable_content)

      Firm.where(uuid: LOPEZ).update_all(balance_cents: 60_000)
      post_bulk(bulk_body([ entry(NAIR, "600") ], payer: LOPEZ), key: "retry-2")

      expect(response).to have_http_status(:created)
      expect(response.headers["Idempotent-Replayed"]).to be_nil
      expect(balances).to include(LOPEZ => 0, NAIR => 260_000)
    end

    scenario "FR-8: a retry is evaluated afresh after a 400" do
      post_bulk(bulk_body([ entry(NAIR, "1.234") ]), key: "retry-3")
      expect(response).to have_http_status(:bad_request)

      post_bulk(bulk_body([ entry(NAIR, "1.23") ]), key: "retry-3")

      expect(response).to have_http_status(:created)
      expect(response.headers["Idempotent-Replayed"]).to be_nil
    end

    scenario "FR-8: a retry is evaluated afresh after a 404" do
      late = create(:firm, balance_cents: 10_000)
      post_bulk(bulk_body([ entry(NAIR, "1") ], payer: "33333333-3333-4333-8333-333333333333"), key: "retry-4")
      expect(response).to have_http_status(:not_found)

      post_bulk(bulk_body([ entry(NAIR, "1") ], payer: late.uuid), key: "retry-4")

      expect(response).to have_http_status(:created)
    end

    scenario "FR-8: keys are scoped per payer" do
      post_bulk(bulk_body([ entry(NAIR, "1") ]), key: "shared")
      post_bulk(bulk_body([ entry(NAIR, "2") ], payer: LOPEZ), key: "shared")

      expect(response).to have_http_status(:created)
      expect(response.headers["Idempotent-Replayed"]).to be_nil
      expect(BulkPayment.order(:id).pluck(:payer_firm_id, :idempotency_key)).to eq([ [ 1, "shared" ], [ 2, "shared" ] ])

      post_bulk(bulk_body([ entry(NAIR, "2") ], payer: LOPEZ), key: "shared")

      expect(response.headers["Idempotent-Replayed"]).to eq("true")
      expect(response.parsed_body["payer_firm_uuid"]).to eq(LOPEZ)
    end

    scenario "precedence: 400 comes before 404, 409 and 422" do
      post_bulk(bulk_body([ entry(NAIR, "x") ], payer: UNKNOWN))
      expect(response).to have_http_status(:bad_request)

      post_bulk(bulk_body([ entry(NAIR, "1") ], payer: UNKNOWN), key: nil)
      expect(response).to have_http_status(:bad_request)

      post_bulk(bulk_body([ entry(UNKNOWN, "1"), entry(NAIR, "abc") ]))
      expect(response).to have_http_status(:bad_request)

      post_bulk(bulk_body([ entry(NAIR, "1") ]), key: "settled")
      post_bulk(bulk_body([ entry(NAIR, "abc") ]), key: "settled")
      expect(response).to have_http_status(:bad_request)
    end

    scenario "precedence: 409 comes before 422" do
      post_bulk(bulk_body([ entry(NAIR, "1") ]), key: "k")
      post_bulk(bulk_body([ entry(NAIR, "9999999") ]), key: "k")

      expect(response).to have_http_status(:conflict)
    end
  end
end
