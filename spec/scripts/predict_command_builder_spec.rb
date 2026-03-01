# frozen_string_literal: true

require "spec_helper"
require_relative "../../scripts/lib/predict_command_builder"

RSpec.describe GK::PredictCommandBuilder do
  it "JSONキーを predict_race CLI引数へ変換する" do
    args = described_class.build(
      "url" => "https://example.com/racedetail/0000000000000000",
      "model_top3" => "data/ml/model.txt",
      "use_exacta_model" => true,
      "use_cache" => false,
      "exacta_top" => 10
    )

    expect(args).to include("--url", "https://example.com/racedetail/0000000000000000")
    expect(args).to include("--model-top3", "data/ml/model.txt")
    expect(args).to include("--exacta-model")
    expect(args).to include("--no-cache")
    expect(args).to include("--exacta-top", "10")
  end
end
