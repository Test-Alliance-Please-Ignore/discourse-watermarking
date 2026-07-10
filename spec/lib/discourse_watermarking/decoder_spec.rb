# frozen_string_literal: true

RSpec.describe DiscourseWatermarking::Decoder do
  fab!(:user)

  before do
    SiteSetting.user_fingerprint_enabled = true
    SiteSetting.user_fingerprint_secret = SecureRandom.hex(32)
  end

  def tile_hex
    DiscourseWatermarking::Payload.tile_hex_for(user.id)
  end

  it "decodes a full 64-bit tile in hex and resolves the user" do
    result = described_class.decode(tile_hex)

    expect(result[:status]).to eq(:matched)
    expect(result[:user]).to eq(user)
    expect(result[:confidence]).to eq("high")
  end

  it "decodes a 56-bit payload without the sync byte" do
    result = described_class.decode(tile_hex[2..])
    expect(result[:status]).to eq(:matched)
    expect(result[:user]).to eq(user)
  end

  it "decodes a binary bitstring with whitespace" do
    bits = tile_hex.to_i(16).to_s(2).rjust(64, "0").scan(/.{8}/).join(" ")
    result = described_class.decode(bits)
    expect(result[:status]).to eq(:matched)
    expect(result[:user]).to eq(user)
  end

  it "decodes a zero-width fingerprint embedded in leaked text" do
    tile = DiscourseWatermarking::Payload.tile_for(user.id)
    leaked = "some quoted forum text#{DiscourseWatermarking::ZeroWidth.encode(tile)} and more"

    result = described_class.decode(leaked)
    expect(result[:status]).to eq(:matched)
    expect(result[:user]).to eq(user)
  end

  it "tolerates a corrupted sync byte because the tag is authoritative" do
    corrupted = "00" + tile_hex[2..]
    expect(described_class.decode(corrupted)[:status]).to eq(:matched)
  end

  it "rejects a forged payload with a valid format but wrong tag" do
    forged =
      DiscourseWatermarking::Payload.payload_for(user.id, secret: "attacker").unpack1("H*")
    expect(described_class.decode(forged)[:status]).to eq(:invalid_signature)
  end

  it "rejects a tampered user code" do
    bytes = DiscourseWatermarking::Payload.tile_for(user.id).bytes
    bytes[3] ^= 0x10
    expect(described_class.decode(bytes.pack("C*").unpack1("H*"))[:status]).to eq(
      :invalid_signature,
    )
  end

  it "tries every candidate in pasted extraction tool output" do
    tool_output = <<~OUTPUT
      Candidate payloads (paste into the admin decoder, best first):
        c514dddddd00ddc5    (score 13.15)
        #{tile_hex}    (score 12.03)
        c51cddddddc5dddd    (score 11.79)
    OUTPUT

    result = described_class.decode(tool_output)
    expect(result[:status]).to eq(:matched)
    expect(result[:user]).to eq(user)
  end

  it "rejects garbage input" do
    expect(described_class.decode("not a watermark")[:status]).to eq(:invalid_input)
    expect(described_class.decode("")[:status]).to eq(:invalid_input)
    expect(described_class.decode("zz" * 8)[:status]).to eq(:invalid_input)
  end

  it "rejects payloads reporting an unsupported version" do
    body = [9 << 4].pack("C") + DiscourseWatermarking::Payload.user_code(user.id)
    payload = body + DiscourseWatermarking::Payload.tag(body, secret: SiteSetting.user_fingerprint_secret)

    result = described_class.decode(payload.unpack1("H*"))
    expect(result[:status]).to eq(:unsupported_version)
    expect(result[:version]).to eq(9)
  end

  it "reports no_match when the matching account no longer exists" do
    hex = tile_hex
    user.destroy!
    expect(described_class.decode(hex)[:status]).to eq(:no_match)
  end

  it "cannot decode payloads generated before a secret rotation" do
    hex = tile_hex
    SiteSetting.user_fingerprint_secret = SecureRandom.hex(32)
    expect(described_class.decode(hex)[:status]).to eq(:invalid_signature)
  end
end
