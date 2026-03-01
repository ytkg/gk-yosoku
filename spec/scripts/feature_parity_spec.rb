# frozen_string_literal: true

require "spec_helper"
require_relative "../../scripts/build_features"
require_relative "../../scripts/predict_race"

RSpec.describe "feature parity between build_features and predict_race" do
  it "同一入力ならモデル入力特徴量が一致する" do
    date = Date.iso8601("2026-02-25")
    racedetail_id = "2320260225030001"
    race = {
      race_id: "2026-02-27-toride-01",
      race_date: Date.iso8601("2026-02-27"),
      start_date: date,
      day_number: 3,
      venue: "toride",
      race_number: 1,
      racedetail_id: racedetail_id
    }

    rows = [
      { "race_date" => "2026-02-27", "venue" => "toride", "race_number" => "1", "racedetail_id" => racedetail_id, "show_result_url" => "", "rank" => "1", "result_status" => "normal", "frame_number" => "", "car_number" => "1", "player_name" => "A", "age" => "", "class" => "", "raw_cells" => "◎|" },
      { "race_date" => "2026-02-27", "venue" => "toride", "race_number" => "1", "racedetail_id" => racedetail_id, "show_result_url" => "", "rank" => "2", "result_status" => "normal", "frame_number" => "", "car_number" => "2", "player_name" => "B", "age" => "", "class" => "", "raw_cells" => "○|" },
      { "race_date" => "2026-02-27", "venue" => "toride", "race_number" => "1", "racedetail_id" => racedetail_id, "show_result_url" => "", "rank" => "3", "result_status" => "normal", "frame_number" => "", "car_number" => "3", "player_name" => "C", "age" => "", "class" => "", "raw_cells" => "▲|" }
    ]

    builder = FeatureBuilder.new(
      from_date: "2026-02-27",
      to_date: "2026-02-27",
      in_dir: "data/raw",
      out_dir: "tmp/features",
      raw_html_dir: "data/raw_html"
    )
    train_rows = builder.send(:build_rows_for_date, rows, race[:race_date])

    entries = rows.map do |r|
      {
        car_number: r["car_number"].to_i,
        player_name: r["player_name"],
        mark_symbol: r["raw_cells"].split("|").first.to_s,
        leg_style: "",
        odds_2shatan_min_first: 9999.9
      }
    end
    stats = rows.each_with_object({}) do |r, h|
      h[r["player_name"]] = { count: 0, win_count: 0, top3_count: 0, rank_sum: 0, last_rank: 0, last_date: nil, recent_ranks: [] }
    end

    predictor = RacePredictor.allocate
    predictor.instance_variable_set(:@same_meet_history, Hash.new { |h, k| h[k] = { count: 0, rank_sum: 0, prev_day_rank: 0 } })
    predictor.instance_variable_set(:@pair_history, Hash.new { |h, k| h[k] = { count: 0, both_top3_count: 0, top3_counts: Hash.new(0) } })
    predictor.instance_variable_set(:@triplet_history, Hash.new { |h, k| h[k] = { count: 0, all_top3_count: 0, top3_counts: Hash.new(0) } })
    predictor.instance_variable_set(:@global_entries, 0)
    predictor.instance_variable_set(:@global_wins, 0)
    predictor.instance_variable_set(:@global_top3, 0)
    predictor.instance_variable_set(
      :@feature_row_builder,
      GK::Core::Features::FeatureBuilder.from_block do |entries:, race:, stats:, global_win_prior:, global_top3_prior:|
        entries.map do |entry|
          predictor.send(
            :build_single_feature_row,
            entry: entry,
            entries: entries,
            race: race,
            stats: stats,
            global_win_prior: global_win_prior,
            global_top3_prior: global_top3_prior
          )
        end
      end
    )
    predict_rows = predictor.send(:build_feature_rows, entries, race, stats)

    columns = GK::FeatureSchema::FEATURE_COLUMNS
    train_comp = train_rows.sort_by { |r| r["car_number"].to_i }.map { |r| columns.to_h { |c| [c, r[c]] } }
    predict_comp = predict_rows.sort_by { |r| r["car_number"].to_i }.map { |r| columns.to_h { |c| [c, r[c]] } }

    expect(predict_comp).to eq(train_comp)
  end
end
