# frozen_string_literal: true

require "spec_helper"
require_relative "../../../core/features/feature_builder"

RSpec.describe GK::Core::Features::FeatureBuilder do
  it "from_block で生成した builder が引数を受け取って返せる" do
    builder = described_class.from_block do |entries:, race:, stats:|
      {
        "entries_size" => entries.size,
        "race_id" => race.fetch("race_id"),
        "stats_size" => stats.size
      }
    end

    result = builder.build(
      entries: [{ "car_number" => 1 }, { "car_number" => 2 }],
      race: { "race_id" => "2026-03-01-toride-01" },
      stats: { "a" => 1 }
    )

    expect(result).to eq(
      "entries_size" => 2,
      "race_id" => "2026-03-01-toride-01",
      "stats_size" => 1
    )
  end

  it "callableでないadapterは初期化エラー" do
    expect { described_class.new(adapter: Object.new) }.to raise_error(ArgumentError)
  end
end
