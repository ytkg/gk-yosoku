# frozen_string_literal: true

require "spec_helper"

RSpec.describe "compare_feature_sets" do
  it "top1/top3 の full と noplayer を比較して推奨セットを出力できる" do
    Dir.mktmpdir("spec-feature-set-compare-") do |tmp|
      top3_full = File.join(tmp, "top3_full.json")
      top3_noplayer = File.join(tmp, "top3_noplayer.json")
      top1_full = File.join(tmp, "top1_full.json")
      top1_noplayer = File.join(tmp, "top1_noplayer.json")

      File.write(top3_full, JSON.pretty_generate({ "top3_exact_match_rate" => 0.21, "winner_hit_rate" => 0.68, "auc" => 0.75 }))
      File.write(top3_noplayer, JSON.pretty_generate({ "top3_exact_match_rate" => 0.19, "winner_hit_rate" => 0.67, "auc" => 0.74 }))
      File.write(top1_full, JSON.pretty_generate({ "winner_hit_rate" => 0.64, "auc" => 0.80 }))
      File.write(top1_noplayer, JSON.pretty_generate({ "winner_hit_rate" => 0.64, "auc" => 0.78 }))

      out_path = File.join(tmp, "feature_set_comparison.json")
      _out, err, st = run_cmd(
        "ruby", "scripts/compare_feature_sets.rb",
        "--top3-full", top3_full,
        "--top3-noplayer", top3_noplayer,
        "--top1-full", top1_full,
        "--top1-noplayer", top1_noplayer,
        "--tie-threshold", "0.001",
        "--out", out_path
      )
      expect(st.success?).to be(true), err

      result = JSON.parse(File.read(out_path, encoding: "UTF-8"))
      expect(result.dig("recommended", "top3_feature_set")).to eq("full")
      expect(result.dig("recommended", "top1_feature_set")).to eq("full")
      expect(result.dig("comparisons", "top3", "primary_metric")).to eq("top3_exact_match_rate")
      expect(result.dig("comparisons", "top1", "primary_metric")).to eq("winner_hit_rate")
    end
  end
end
