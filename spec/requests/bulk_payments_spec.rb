require "rails_helper"

RSpec.describe "POST /bulk_payments", type: :request do
  before { seed_brief_firms }

  def error_fields
    error_body.dig("details", "errors").map { |error| [ error["index"], error["field"] ] }
  end

  def expect_nothing_changed
    expect(BulkPayment.count).to eq(0)
    expect(Payment.count).to eq(0)
    expect(balances.slice(PINECREST, LOPEZ, NAIR)).to eq(PINECREST => 5_000_000, LOPEZ => 50_000, NAIR => 200_000)
  end

  describe "AC-1: the brief's sample request" do
    let(:sample) do
      bulk_body([
        entry(NAIR, "6250", "Overflow returns, August 2026"),
        entry(NAIR, "5800.5", "Amended returns, August 2026"),
        entry(LOPEZ, "1200.75", "Bookkeeping cleanup, 3 clients")
      ])
    end

    before { post_bulk(sample, key: "brief-sample-1") }

    it "responds 201 with exact totals and payments in request order" do
      expect(response).to have_http_status(:created)
      expect(response.headers["Idempotent-Replayed"]).to be_nil
      expect(response.parsed_body).to match(
        "id" => BulkPayment.sole.id,
        "payer_firm_uuid" => PINECREST,
        "total_amount" => "13251.25",
        "payments" => [
          { "id" => an_instance_of(Integer), "payee_firm_uuid" => NAIR, "amount" => "6250.00", "description" => "Overflow returns, August 2026" },
          { "id" => an_instance_of(Integer), "payee_firm_uuid" => NAIR, "amount" => "5800.50", "description" => "Amended returns, August 2026" },
          { "id" => an_instance_of(Integer), "payee_firm_uuid" => LOPEZ, "amount" => "1200.75", "description" => "Bookkeeping cleanup, 3 clients" }
        ]
      )
    end

    it "moves exactly the right cents between firms" do
      expect(balances).to eq(PINECREST => 3_674_875, LOPEZ => 170_075, NAIR => 1_405_050)
      expect(balances.values.sum).to eq(5_250_000)
    end

    it "stores one bulk payment and three separate payments with ascending ids" do
      bulk = BulkPayment.sole
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
  end

  describe "FR-2: bulk payments and payments" do
    let(:payees) { create_list(:firm, 5, balance_cents: 0) }

    it "stores payment ids ascending in request order, matching the response" do
      amounts = %w[5 4 3 2 1]
      post_bulk(bulk_body(payees.zip(amounts).map { |firm, amount| entry(firm.uuid, amount, "To #{firm.name}") }))

      stored = Payment.order(:id).pluck(:id, :payee_firm_id)
      expect(stored.map(&:last)).to eq(payees.map(&:id))
      expect(response.parsed_body["payments"].map { |payment| payment["id"] }).to eq(stored.map(&:first))
      expect(stored.map(&:first)).to eq(stored.map(&:first).sort)
    end

    it "does not merge entries to the same payee" do
      post_bulk(bulk_body([ entry(LOPEZ, "1"), entry(LOPEZ, "1"), entry(LOPEZ, "1") ]))

      expect(Payment.where(payee_firm_id: 2).pluck(:amount_cents)).to eq([ 100, 100, 100 ])
    end

    it "makes accepted rows immutable" do
      post_bulk(bulk_body([ entry(LOPEZ, "1") ]))

      expect { BulkPayment.sole.update!(total_amount_cents: 1) }.to raise_error(ActiveRecord::ReadOnlyRecord)
      expect { BulkPayment.sole.destroy! }.to raise_error(ActiveRecord::ReadOnlyRecord)
      expect { Payment.sole.update!(amount_cents: 1) }.to raise_error(ActiveRecord::ReadOnlyRecord)
      expect { Payment.sole.destroy! }.to raise_error(ActiveRecord::ReadOnlyRecord)
    end
  end

  describe "FR-3: submission" do
    it "ignores fields beyond the documented ones" do
      body = bulk_body([ entry(LOPEZ, "1").merge("note" => "x", "amount_cents" => 99_999) ]).merge("extra" => { "a" => 1 })
      post_bulk(body)

      expect(response).to have_http_status(:created)
      expect(Payment.sole.amount_cents).to eq(100)
    end

    it "accepts the body without relying on the content type" do
      post "/bulk_payments", params: bulk_body([ entry(LOPEZ, "1") ]).to_json,
        headers: { "CONTENT_TYPE" => "text/plain", "Idempotency-Key" => "k" }

      expect(response).to have_http_status(:created)
    end
  end

  describe "FR-4: request validation" do
    let(:valid_entry) { entry(LOPEZ, "1") }

    describe "Idempotency-Key" do
      it "rejects a missing key" do
        post_bulk(bulk_body([ valid_entry ]), key: nil)

        expect(response).to have_http_status(:bad_request)
        expect(error_body["code"]).to eq("invalid_request")
        expect(error_fields).to eq([ [ nil, "Idempotency-Key" ] ])
      end

      [ "", "a" * 256, "café", "tab\tkey" ].each do |key|
        it "rejects #{key.inspect[0, 20]}" do
          post_bulk(bulk_body([ valid_entry ]), key:)

          expect(response).to have_http_status(:bad_request)
          expect(error_fields).to eq([ [ nil, "Idempotency-Key" ] ])
          expect_nothing_changed
        end
      end

      it "accepts 1 and 255 printable ASCII characters including spaces and symbols" do
        post_bulk(bulk_body([ valid_entry ]), key: "a")
        post_bulk(bulk_body([ entry(LOPEZ, "2") ]), key: "~ #{'!' * 251} ~")
        post_bulk(bulk_body([ entry(LOPEZ, "3") ]), key: "z" * 255)

        expect(BulkPayment.count).to eq(3)
      end
    end

    describe "body shape" do
      [ "", "not json", "{", "[]", "\"text\"", "42", "null", "[{}]" ].each do |raw|
        it "rejects the body #{raw.inspect}" do
          post_bulk(raw)

          expect(response).to have_http_status(:bad_request)
          expect(error_body["code"]).to eq("invalid_request")
          expect_nothing_changed
        end
      end

      it "rejects a body that is not valid UTF-8 with the documented error object" do
        post_bulk("{\"payer_firm_uuid\":\"\xFF\"}".b)

        expect(response).to have_http_status(:bad_request)
        expect(error_body["code"]).to eq("invalid_request")
      end

      it "reports missing required fields" do
        post_bulk({})

        expect(error_fields).to contain_exactly([ nil, "payer_firm_uuid" ], [ nil, "payments" ])
      end

      it "reports wrong JSON types for top-level fields" do
        post_bulk({ "payer_firm_uuid" => 5, "payments" => { "0" => {} } })

        expect(error_fields).to contain_exactly([ nil, "payer_firm_uuid" ], [ nil, "payments" ])
      end

      it "reports entries that are not objects, and missing or mistyped entry fields, by index" do
        post_bulk(bulk_body([
          valid_entry,
          "nope",
          {},
          { "amount" => 5, "payee_firm_uuid" => 7, "description" => [] }
        ]))

        expect(error_fields).to contain_exactly(
          [ 1, "payments" ],
          [ 2, "payee_firm_uuid" ], [ 2, "amount" ], [ 2, "description" ],
          [ 3, "payee_firm_uuid" ], [ 3, "amount" ], [ 3, "description" ]
        )
      end
    end

    describe "UUIDs" do
      it "rejects malformed uuids and reports each index" do
        post_bulk(bulk_body([ entry("nope", "1"), valid_entry, entry(LOPEZ.delete("-"), "1"), entry("#{LOPEZ}0", "1") ],
          payer: "not-a-uuid"))

        expect(response).to have_http_status(:bad_request)
        expect(error_fields).to contain_exactly(
          [ nil, "payer_firm_uuid" ], [ 0, "payee_firm_uuid" ], [ 2, "payee_firm_uuid" ], [ 3, "payee_firm_uuid" ]
        )
      end

      it "matches uuids case-insensitively" do
        post_bulk(bulk_body([ entry(LOPEZ.upcase, "1") ], payer: PINECREST.upcase))

        expect(response).to have_http_status(:created)
        expect(response.parsed_body).to include("payer_firm_uuid" => PINECREST)
        expect(response.parsed_body["payments"].first).to include("payee_firm_uuid" => LOPEZ)
      end

      it "rejects a payee equal to the payer, even in different letter case" do
        post_bulk(bulk_body([ valid_entry, entry(PINECREST.upcase, "1") ]))

        expect(response).to have_http_status(:bad_request)
        expect(error_fields).to eq([ [ 1, "payee_firm_uuid" ] ])
        expect_nothing_changed
      end
    end

    describe "payments array" do
      it "rejects an empty array" do
        post_bulk(bulk_body([]))

        expect(response).to have_http_status(:bad_request)
        expect(error_fields).to eq([ [ nil, "payments" ] ])
      end

      it "rejects more than 1,000 entries and accepts exactly 1,000" do
        post_bulk(bulk_body(Array.new(1_001) { valid_entry }))
        expect(response).to have_http_status(:bad_request)
        expect(error_fields).to eq([ [ nil, "payments" ] ])
        expect_nothing_changed

        post_bulk(bulk_body(Array.new(1_000) { valid_entry }), key: "thousand")
        expect(response).to have_http_status(:created)
        expect(Payment.count).to eq(1_000)
      end
    end

    describe "amounts" do
      [ "1e3", "-1", "+1", " 1", "1 ", "1,000", "1.", ".5", "1.005", "abc", "", "１２", "1\n", "0x10", "1_000", "1.5.0",
        "$1", "1e-2", "NaN", "Infinity" ].each do |amount|
        it "rejects the string #{amount.inspect}" do
          post_bulk(bulk_body([ valid_entry, entry(LOPEZ, amount) ]))

          expect(response).to have_http_status(:bad_request)
          expect(error_fields).to eq([ [ 1, "amount" ] ])
          expect_nothing_changed
        end
      end

      [ 100, 1.5, true, [], {} ].each do |amount|
        it "rejects the JSON #{amount.class} #{amount.inspect}" do
          post_bulk(bulk_body([ entry(LOPEZ, amount) ]))

          expect(response).to have_http_status(:bad_request)
          expect(error_fields).to eq([ [ 0, "amount" ] ])
        end
      end

      it "rejects null and a missing amount" do
        post_bulk(bulk_body([ entry(LOPEZ, nil), { "payee_firm_uuid" => LOPEZ, "description" => "x" } ]))

        expect(error_fields).to eq([ [ 0, "amount" ], [ 1, "amount" ] ])
      end

      %w[0 0.0 0.00 000 21474836.48 21474837 99999999999 99999999999999999999999999999999999999].each do |amount|
        it "rejects #{amount} as outside $0.01 to $21,474,836.47" do
          post_bulk(bulk_body([ entry(LOPEZ, amount) ]))

          expect(response).to have_http_status(:bad_request)
          expect(error_fields).to eq([ [ 0, "amount" ] ])
        end
      end

      it "rejects a very long digit string without trouble" do
        post_bulk(bulk_body([ entry(LOPEZ, "9" * 10_000) ]))

        expect(response).to have_http_status(:bad_request)
        expect(error_fields).to eq([ [ 0, "amount" ] ])
      end

      it "accepts leading zeros, one decimal and two decimals" do
        post_bulk(bulk_body([ entry(LOPEZ, "007"), entry(LOPEZ, "0.5"), entry(LOPEZ, "0.05"), entry(LOPEZ, "00000000000000000001.10") ]))

        expect(response).to have_http_status(:created)
        expect(Payment.order(:id).pluck(:amount_cents)).to eq([ 700, 50, 5, 110 ])
      end

      it "rejects a request whose total exceeds $21,474,836.47 though every amount is valid" do
        post_bulk(bulk_body([ entry(LOPEZ, "21474836.47"), entry(NAIR, "0.01") ]))

        expect(response).to have_http_status(:bad_request)
        expect(error_fields).to eq([ [ nil, "payments" ] ])
        expect_nothing_changed
      end

      it "rejects a total built from many entries that would overflow 32 bits" do
        post_bulk(bulk_body(Array.new(300) { entry(LOPEZ, "100000") }))

        expect(response).to have_http_status(:bad_request)
        expect(error_fields).to eq([ [ nil, "payments" ] ])
      end
    end

    describe "descriptions" do
      [ "", " ", "  \t\n ", " ", "　" ].each do |description|
        it "rejects the blank description #{description.inspect}" do
          post_bulk(bulk_body([ entry(LOPEZ, "1", description) ]))

          expect(response).to have_http_status(:bad_request)
          expect(error_fields).to eq([ [ 0, "description" ] ])
        end
      end

      it "rejects a NUL character" do
        post_bulk(bulk_body([ entry(LOPEZ, "1", "a\u0000b") ]))

        expect(response).to have_http_status(:bad_request)
        expect(error_fields).to eq([ [ 0, "description" ] ])
        expect_nothing_changed
      end

      it "rejects 256 characters and accepts 255, counting characters rather than bytes" do
        post_bulk(bulk_body([ entry(LOPEZ, "1", "é" * 256) ]))
        expect(error_fields).to eq([ [ 0, "description" ] ])

        post_bulk(bulk_body([ entry(LOPEZ, "1", "é" * 255), entry(LOPEZ, "1", "日本語 🎉") ]), key: "ok")
        expect(response).to have_http_status(:created)
        expect(Payment.order(:id).pluck(:description)).to eq([ "é" * 255, "日本語 🎉" ])
      end

      it "stores descriptions verbatim, including surrounding whitespace" do
        post_bulk(bulk_body([ entry(LOPEZ, "1", "  padded  ") ]))

        expect(Payment.sole.description).to eq("  padded  ")
      end
    end

    it "reports every offending entry, not only the first" do
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
    end
  end

  describe "FR-5: firm resolution" do
    it "answers 404 payer_not_found for an unknown payer" do
      post_bulk(bulk_body([ entry(LOPEZ, "1") ], payer: UNKNOWN))

      expect(response).to have_http_status(:not_found)
      expect(error_body).to include("code" => "payer_not_found", "message" => a_kind_of(String))
      expect(error_body).not_to have_key("details")
      expect_nothing_changed
    end

    it "denies the whole request with 422 listing every distinct unknown payee" do
      other = "11111111-1111-4111-8111-111111111111"
      post_bulk(bulk_body([ entry(LOPEZ, "1"), entry(UNKNOWN, "1"), entry(other, "1"), entry(UNKNOWN, "1") ]))

      expect(response).to have_http_status(:unprocessable_content)
      expect(error_body["code"]).to eq("payee_not_found")
      expect(error_body["details"]).to eq("unknown_payee_firm_uuids" => [ UNKNOWN, other ])
      expect_nothing_changed
    end

    it "answers 404 before 422 when both the payer and a payee are unknown" do
      post_bulk(bulk_body([ entry(UNKNOWN, "1") ], payer: "22222222-2222-4222-8222-222222222222"))

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "FR-6: funds check and settlement" do
    it "accepts a request that spends the payer's balance to exactly zero" do
      post_bulk(bulk_body([ entry(NAIR, "500.00") ], payer: LOPEZ))

      expect(response).to have_http_status(:created)
      expect(balances).to include(LOPEZ => 0, NAIR => 250_000)
    end

    it "denies a request one cent over the payer's balance and leaves no trace" do
      post_bulk(bulk_body([ entry(NAIR, "500.01") ], payer: LOPEZ))

      expect(response).to have_http_status(:unprocessable_content)
      expect(error_body["code"]).to eq("insufficient_funds")
      expect(error_body["details"]).to eq("required_total" => "500.01")
      expect(response.body).not_to match(/50000|500\.00|balance_cents/)
      expect_nothing_changed
    end

    it "checks the sum of all entries, not each entry on its own" do
      post_bulk(bulk_body([ entry(NAIR, "300"), entry(PINECREST, "200.01") ], payer: LOPEZ))

      expect(response).to have_http_status(:unprocessable_content)
      expect(error_body["code"]).to eq("insufficient_funds")
      expect_nothing_changed
    end

    describe "payee balance limit" do
      let(:max) { 2_147_483_647 }
      let!(:near_max) { create(:firm, balance_cents: max - 100) }

      it "accepts a credit that lands exactly on the maximum" do
        post_bulk(bulk_body([ entry(near_max.uuid, "1.00") ]))

        expect(response).to have_http_status(:created)
        expect(near_max.reload.balance_cents).to eq(max)
      end

      it "denies a credit one cent over the maximum, listing the payee, and leaves the other payees alone" do
        post_bulk(bulk_body([ entry(LOPEZ, "5"), entry(near_max.uuid, "1.01") ]))

        expect(response).to have_http_status(:unprocessable_content)
        expect(error_body["code"]).to eq("payee_balance_limit_exceeded")
        expect(error_body["details"]).to eq("payee_firm_uuids" => [ near_max.uuid ])
        expect(near_max.reload.balance_cents).to eq(max - 100)
        expect_nothing_changed
      end

      it "sums entries to the same payee before checking the limit" do
        post_bulk(bulk_body([ entry(near_max.uuid, "0.60"), entry(near_max.uuid, "0.60") ]))

        expect(response).to have_http_status(:unprocessable_content)
        expect(error_body["details"]).to eq("payee_firm_uuids" => [ near_max.uuid ])
        expect(near_max.reload.balance_cents).to eq(max - 100)
      end

      it "lists every affected payee" do
        second = create(:firm, balance_cents: max)
        post_bulk(bulk_body([ entry(near_max.uuid, "2"), entry(second.uuid, "0.01") ]))

        expect(error_body["details"]["payee_firm_uuids"]).to contain_exactly(near_max.uuid, second.uuid)
      end

      it "reports insufficient funds before payee limits" do
        post_bulk(bulk_body([ entry(near_max.uuid, "600") ], payer: LOPEZ))

        expect(error_body["code"]).to eq("insufficient_funds")
      end
    end

    it "moves a full-range amount without 32-bit overflow" do
      rich = create(:firm, balance_cents: 2_147_483_647)
      poor = create(:firm, balance_cents: 0)
      post_bulk(bulk_body([ entry(poor.uuid, "21474836.47") ], payer: rich.uuid))

      expect(response).to have_http_status(:created)
      expect(rich.reload.balance_cents).to eq(0)
      expect(poor.reload.balance_cents).to eq(2_147_483_647)
    end

    it "keeps the sum of all balances unchanged" do
      before_total = Firm.sum(:balance_cents)
      post_bulk(bulk_body([ entry(NAIR, "10.10"), entry(LOPEZ, "0.01"), entry(NAIR, "99.99") ]))

      expect(Firm.sum(:balance_cents)).to eq(before_total)
    end

    describe "exact cent arithmetic" do
      # Each of these is a classic Float trap: 4.35 * 100 == 434.99999999999994 and so on.
      {
        "4.35" => 435, "1.15" => 115, "8.2" => 820, "0.29" => 29, "0.57" => 57, "1.1" => 110, "19.99" => 1_999,
        "2.675" => nil, "0.1" => 10, "0.7" => 70, "33.33" => 3_333, "12345.67" => 1_234_567
      }.compact.each do |amount, cents|
        it "converts #{amount} to #{cents} cents" do
          post_bulk(bulk_body([ entry(LOPEZ, amount) ]))

          expect(Payment.sole.amount_cents).to eq(cents)
          expect(response.parsed_body["total_amount"]).to eq(format("%d.%02d", cents / 100, cents % 100))
          expect(balances[LOPEZ]).to eq(50_000 + cents)
        end
      end

      it "sums 0.1 and 0.2 to exactly 0.30" do
        post_bulk(bulk_body([ entry(LOPEZ, "0.1"), entry(LOPEZ, "0.2") ]))

        expect(response.parsed_body["total_amount"]).to eq("0.30")
        expect(BulkPayment.sole.total_amount_cents).to eq(30)
        expect(balances).to include(LOPEZ => 50_030, PINECREST => 4_999_970)
      end

      it "sums a thousand cents-sized entries to exactly ten dollars" do
        post_bulk(bulk_body(Array.new(1_000) { entry(LOPEZ, "0.01") }))

        expect(response.parsed_body["total_amount"]).to eq("10.00")
        expect(balances).to include(LOPEZ => 51_000, PINECREST => 4_999_000)
      end

      it "sums many awkward amounts to the exact total" do
        amounts = %w[19.99 19.99 19.99 0.07 0.07 0.07 33.33 33.34 0.29 0.58 1.15 4.35]
        post_bulk(bulk_body(amounts.map { |amount| entry(NAIR, amount) }))

        expected = amounts.sum { |amount| amount.delete(".").to_i * (amount.include?(".") ? 10**(2 - amount.split(".").last.size) : 100) }
        expect(BulkPayment.sole.total_amount_cents).to eq(expected)
        expect(balances[NAIR]).to eq(200_000 + expected)
        expect(balances[PINECREST]).to eq(5_000_000 - expected)
      end
    end

    it "leaves no bulk payment, payments or balance change when the write fails midway" do
      ActiveRecord::Base.connection.execute(<<~SQL)
        CREATE FUNCTION fail_payment_insert() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN RAISE EXCEPTION 'forced failure'; END $$;
        CREATE TRIGGER fail_payment_insert BEFORE INSERT ON payments
          FOR EACH ROW EXECUTE FUNCTION fail_payment_insert();
      SQL

      post_bulk(bulk_body([ entry(NAIR, "10"), entry(LOPEZ, "10") ]))

      expect(response).to have_http_status(:internal_server_error)
      expect(error_body).to include("code" => "internal_error", "message" => a_kind_of(String))
      expect_nothing_changed
    end
  end

  describe "FR-7: responses" do
    it "renders amounts as dollar strings with exactly two decimals" do
      post_bulk(bulk_body([ entry(NAIR, "300"), entry(NAIR, "0.5"), entry(NAIR, "12.3"), entry(NAIR, "10000") ]))

      expect(response.parsed_body["payments"].map { |payment| payment["amount"] }).to eq(%w[300.00 0.50 12.30 10000.00])
      expect(response.parsed_body["total_amount"]).to eq("10312.80")
    end

    it "carries the keys id, payer_firm_uuid, total_amount and payments, and per payment id, payee_firm_uuid, amount, description" do
      post_bulk(bulk_body([ entry(NAIR, "1") ]))

      expect(response.parsed_body.keys).to contain_exactly("id", "payer_firm_uuid", "total_amount", "payments")
      expect(response.parsed_body["payments"].first.keys).to contain_exactly("id", "payee_firm_uuid", "amount", "description")
    end

    it "returns JSON for every error" do
      post_bulk(bulk_body([ entry(NAIR, "1") ], payer: UNKNOWN))

      expect(response.media_type).to eq("application/json")
      expect(error_body.keys).to include("code", "message")
    end
  end

  describe "FR-8: idempotent retries" do
    let(:request_body) { bulk_body([ entry(NAIR, "300"), entry(LOPEZ, "12.5", "Cleanup") ]) }

    it "stores the key and a fingerprint on the bulk payment" do
      post_bulk(request_body, key: "retry-1")

      expect(BulkPayment.sole).to have_attributes(idempotency_key: "retry-1", request_fingerprint: match(/\A\h{64}\z/))
    end

    context "when the same request is retried" do
      let!(:original) do
        post_bulk(request_body, key: "retry-1")
        response.parsed_body
      end

      it "replays with 201 and Idempotent-Replayed, without settling again" do
        post_bulk(request_body, key: "retry-1")

        expect(response).to have_http_status(:created)
        expect(response.headers["Idempotent-Replayed"]).to eq("true")
        expect(response.parsed_body).to eq(original)
        expect(BulkPayment.count).to eq(1)
        expect(Payment.count).to eq(2)
        expect(balances).to eq(PINECREST => 4_968_750, LOPEZ => 51_250, NAIR => 230_000)
      end

      it "replays regardless of current balances" do
        Firm.where(uuid: PINECREST).update_all(balance_cents: 0)

        post_bulk(request_body, key: "retry-1")

        expect(response).to have_http_status(:created)
        expect(response.headers["Idempotent-Replayed"]).to eq("true")
        expect(response.parsed_body).to eq(original)
        expect(balances[PINECREST]).to eq(0)
      end

      it "replays when only formatting differs" do
        variants = [
          %({"payments":[{"description":"Invoice","payee_firm_uuid":"#{NAIR.upcase}","amount":"300.00"},
                         {"description":"Cleanup","payee_firm_uuid":"#{LOPEZ}","amount":"12.50"}],
             "payer_firm_uuid":"#{PINECREST}"}),
          %(  { "payer_firm_uuid" : "#{PINECREST.upcase}" , "ignored": true, "payments" : [
              { "amount" : "0300", "payee_firm_uuid" : "#{NAIR}", "description" : "Invoice" },
              { "amount" : "12.5", "payee_firm_uuid" : "#{LOPEZ}", "description" : "Cleanup" } ] }  \n)
        ]

        variants.each do |raw|
          post_bulk(raw, key: "retry-1")

          expect(response).to have_http_status(:created)
          expect(response.headers["Idempotent-Replayed"]).to eq("true")
          expect(response.parsed_body).to eq(original)
        end
        expect(BulkPayment.count).to eq(1)
      end
    end

    context "when the key is reused for a different request" do
      before { post_bulk(request_body, key: "retry-1") }

      {
        "another amount" => -> { bulk_body([ entry(NAIR, "300.01"), entry(LOPEZ, "12.5", "Cleanup") ]) },
        "another description" => -> { bulk_body([ entry(NAIR, "300"), entry(LOPEZ, "12.5", "cleanup") ]) },
        "another payee" => -> { bulk_body([ entry(LOPEZ, "300"), entry(LOPEZ, "12.5", "Cleanup") ]) },
        "another order" => -> { bulk_body([ entry(LOPEZ, "12.5", "Cleanup"), entry(NAIR, "300") ]) },
        "an extra entry" => -> { bulk_body([ entry(NAIR, "300"), entry(LOPEZ, "12.5", "Cleanup"), entry(NAIR, "1") ]) }
      }.each do |difference, build|
        it "answers 409 for #{difference} and changes nothing" do
          post_bulk(instance_exec(&build), key: "retry-1")

          expect(response).to have_http_status(:conflict)
          expect(error_body).to include("code" => "idempotency_key_reused")
          expect(BulkPayment.count).to eq(1)
          expect(Payment.count).to eq(2)
          expect(balances).to eq(PINECREST => 4_968_750, LOPEZ => 51_250, NAIR => 230_000)
        end
      end

      it "answers 409 before 422, even when the new request would be denied" do
        post_bulk(bulk_body([ entry(UNKNOWN, "1") ]), key: "retry-1")

        expect(response).to have_http_status(:conflict)
      end
    end

    it "evaluates a retry afresh after a 422" do
      post_bulk(bulk_body([ entry(NAIR, "600") ], payer: LOPEZ), key: "retry-2")
      expect(response).to have_http_status(:unprocessable_content)

      Firm.where(uuid: LOPEZ).update_all(balance_cents: 60_000)
      post_bulk(bulk_body([ entry(NAIR, "600") ], payer: LOPEZ), key: "retry-2")

      expect(response).to have_http_status(:created)
      expect(response.headers["Idempotent-Replayed"]).to be_nil
      expect(balances).to include(LOPEZ => 0, NAIR => 260_000)
    end

    it "evaluates a retry afresh after a 400" do
      post_bulk(bulk_body([ entry(NAIR, "1.234") ]), key: "retry-3")
      expect(response).to have_http_status(:bad_request)

      post_bulk(bulk_body([ entry(NAIR, "1.23") ]), key: "retry-3")
      expect(response).to have_http_status(:created)
      expect(response.headers["Idempotent-Replayed"]).to be_nil
    end

    it "evaluates a retry afresh after a 404" do
      late = create(:firm, balance_cents: 10_000)
      post_bulk(bulk_body([ entry(NAIR, "1") ], payer: "33333333-3333-4333-8333-333333333333"), key: "retry-4")
      expect(response).to have_http_status(:not_found)

      post_bulk(bulk_body([ entry(NAIR, "1") ], payer: late.uuid), key: "retry-4")
      expect(response).to have_http_status(:created)
    end

    it "scopes keys per payer" do
      post_bulk(bulk_body([ entry(NAIR, "1") ]), key: "shared")
      post_bulk(bulk_body([ entry(NAIR, "2") ], payer: LOPEZ), key: "shared")

      expect(response).to have_http_status(:created)
      expect(response.headers["Idempotent-Replayed"]).to be_nil
      expect(BulkPayment.order(:id).pluck(:payer_firm_id, :idempotency_key)).to eq([ [ 1, "shared" ], [ 2, "shared" ] ])

      post_bulk(bulk_body([ entry(NAIR, "2") ], payer: LOPEZ), key: "shared")
      expect(response.headers["Idempotent-Replayed"]).to eq("true")
      expect(response.parsed_body["payer_firm_uuid"]).to eq(LOPEZ)
    end
  end

  describe "error precedence" do
    it "answers 400 before 404 when the payer is unknown and the body is invalid" do
      post_bulk(bulk_body([ entry(NAIR, "x") ], payer: UNKNOWN))

      expect(response).to have_http_status(:bad_request)
    end

    it "answers 400 for a missing key even when the payer is unknown" do
      post_bulk(bulk_body([ entry(NAIR, "1") ], payer: UNKNOWN), key: nil)

      expect(response).to have_http_status(:bad_request)
    end

    it "answers 400 before 422 for an invalid amount alongside an unknown payee" do
      post_bulk(bulk_body([ entry(UNKNOWN, "1"), entry(NAIR, "abc") ]))

      expect(response).to have_http_status(:bad_request)
    end

    it "answers 409 before 422" do
      post_bulk(bulk_body([ entry(NAIR, "1") ]), key: "k")
      post_bulk(bulk_body([ entry(NAIR, "9999999") ]), key: "k")

      expect(response).to have_http_status(:conflict)
    end
  end
end
