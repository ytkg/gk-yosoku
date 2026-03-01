# frozen_string_literal: true

require "spec_helper"
require_relative "../../scripts/lib/feature_engine_common"

RSpec.describe GK::FeatureEngineCommon do
  it "相対ランク系の派生特徴量を安定して付与する" do
    rows = [
      {
        "car_number" => "1",
        "hist_avg_rank" => "1.500000",
        "hist_recent3_top3_rate" => "1.000000",
        "hist_top3_rate" => "0.900000",
        "hist_recent5_top3_rate" => "0.800000",
        "same_meet_prev_day_rank" => "1",
        "same_meet_avg_rank" => "1.500000",
        "pair_hist_i_top3_rate_avg" => "0.700000",
        "triplet_hist_i_top3_rate_avg" => "0.600000",
        "hist_win_rate" => "0.500000",
        "mark_score" => "5.0",
        "odds_2shatan_min_first" => "2.000000"
      },
      {
        "car_number" => "2",
        "hist_avg_rank" => "2.500000",
        "hist_recent3_top3_rate" => "0.600000",
        "hist_top3_rate" => "0.500000",
        "hist_recent5_top3_rate" => "0.550000",
        "same_meet_prev_day_rank" => "2",
        "same_meet_avg_rank" => "2.500000",
        "pair_hist_i_top3_rate_avg" => "0.400000",
        "triplet_hist_i_top3_rate_avg" => "0.350000",
        "hist_win_rate" => "0.300000",
        "mark_score" => "3.0",
        "odds_2shatan_min_first" => "4.000000"
      },
      {
        "car_number" => "3",
        "hist_avg_rank" => "0.0",
        "hist_recent3_top3_rate" => "0.700000",
        "hist_top3_rate" => "0.700000",
        "hist_recent5_top3_rate" => "0.650000",
        "same_meet_prev_day_rank" => "0",
        "same_meet_avg_rank" => "0.0",
        "pair_hist_i_top3_rate_avg" => "0.500000",
        "triplet_hist_i_top3_rate_avg" => "0.450000",
        "hist_win_rate" => "0.200000",
        "mark_score" => "4.0",
        "odds_2shatan_min_first" => "3.000000"
      }
    ]

    described_class.enrich_relative_ranks!(rows)

    car1 = rows.find { |r| r["car_number"] == "1" }
    car2 = rows.find { |r| r["car_number"] == "2" }
    car3 = rows.find { |r| r["car_number"] == "3" }

    expect(car1["recent3_vs_hist_top3_delta"]).to eq("0.100000")
    expect(car2["same_meet_prev_day_rank_inv"]).to eq("0.500000")
    expect(car3["same_meet_prev_day_rank_inv"]).to eq("0.000000")

    expect(car1["race_rel_hist_avg_rank_rank"]).to eq("1")
    expect(car2["race_rel_hist_avg_rank_rank"]).to eq("2")
    expect(car3["race_rel_hist_avg_rank_rank"]).to eq("3")

    expect(car1["race_rel_hist_recent3_top3_rate_rank"]).to eq("1")
    expect(car3["race_rel_hist_recent3_top3_rate_rank"]).to eq("2")
    expect(car2["race_rel_hist_recent3_top3_rate_rank"]).to eq("3")

    expect(car1["race_rel_odds_2shatan_rank"]).to eq("1")
    expect(car3["race_rel_odds_2shatan_rank"]).to eq("2")
    expect(car2["race_rel_odds_2shatan_rank"]).to eq("3")
  end
end
