# frozen_string_literal: true

RSpec.describe DiscourseWatermarking::ZeroWidth do
  let(:tile) { (+"\xC5\x1F\xA2\xB3\xC4\xD5\xE6\xF7").force_encoding(Encoding::BINARY) }

  it "round-trips arbitrary tile bytes" do
    expect(described_class.decode(described_class.encode(tile))).to eq(tile)
  end

  it "produces only invisible characters" do
    encoded = described_class.encode(tile)
    expect(encoded.chars).to all(match(described_class::ANY_ZERO_WIDTH))
    expect(encoded.length).to eq(4 + 32)
  end

  it "matches the client-side test vector for a known input" do
    # Cross-language vector shared with test/javascripts/unit/watermark-lib-test.js
    encoded = described_class.encode((+"\xC5\x00\x00\x00\x00\x00\x00\x00").force_encoding(Encoding::BINARY))
    expect(encoded).to eq(
      described_class::MARKER + "\u2060\u200B\u200C\u200C" + "\u200B" * 28,
    )
  end

  it "finds a fingerprint embedded in surrounding text" do
    text = "before #{described_class.encode(tile)} after"
    expect(described_class.decode(text)).to eq(tile)
  end

  it "returns nil when no fingerprint is present" do
    expect(described_class.decode("plain text")).to be_nil
    expect(described_class.decode("stray\u200Bzero\u200Cwidth")).to be_nil
  end

  it "returns nil for a truncated fingerprint" do
    truncated = described_class.encode(tile)[0..-3]
    expect(described_class.decode(truncated)).to be_nil
  end

  it "strips every zero-width character" do
    text = "a#{described_class.encode(tile)}b\uFEFFc"
    expect(described_class.strip(text)).to eq("abc")
  end
end
