require "rails_helper"

RSpec.describe BulkPayments::Amount do
  describe ".parse" do
    {
      "0" => 0, "0.01" => 1, "0.1" => 10, "0.10" => 10, "1" => 100, "1.5" => 150, "5800.5" => 580_050, "1200.75" => 120_075,
      "007" => 700, "21474836.47" => 2_147_483_647,
      # Products of these and 100 are off by one ulp in binary floating point.
      "4.35" => 435, "1.15" => 115, "8.2" => 820, "0.29" => 29, "0.57" => 57, "1.00" => 100
    }.each do |string, cents|
      it("parses #{string.inspect} as #{cents} cents") { expect(described_class.parse(string)).to eq(cents) }
    end

    it "returns Integer, never Float or BigDecimal" do
      expect(described_class.parse("19.99")).to be_an(Integer)
    end

    [ "", " ", "1.", ".5", "1.005", "-1", "+1", "1e3", "1,0", "1 ", " 1", "1\n", "１", "1.0.0", "0x1", "١٢", nil, 1, 1.5, [], {} ].each do |value|
      it("rejects #{value.inspect}") { expect(described_class.parse(value)).to be_nil }
    end

    it "rejects strings with invalid encoding" do
      expect(described_class.parse("1\xFF")).to be_nil
    end

    it "parses amounts beyond the maximum to a value above it, and long digit strings to just above it" do
      expect(described_class.parse("21474836.48")).to eq(described_class::OVER_MAX)
      expect(described_class.parse("2147483647")).to be > described_class::MAX_CENTS
      expect(described_class.parse("99999999999")).to eq(described_class::OVER_MAX)
      expect(described_class.parse("9" * 10_000)).to eq(described_class::OVER_MAX)
      expect(described_class.parse("0" * 10_000 + "1")).to eq(100)
    end
  end

  describe ".format" do
    { 0 => "0.00", 1 => "0.01", 10 => "0.10", 100 => "1.00", 580_050 => "5800.50", 1_325_125 => "13251.25",
      2_147_483_647 => "21474836.47" }.each do |cents, string|
      it("formats #{cents} as #{string}") { expect(described_class.format(cents)).to eq(string) }
    end
  end

  it "round-trips every cent value from 0 to 250,000 and the 32-bit boundary" do
    mismatches = ((0..250_000).to_a + (2_147_483_447..2_147_483_647).to_a).reject do |cents|
      described_class.parse(described_class.format(cents)) == cents
    end

    expect(mismatches).to be_empty
  end
end
