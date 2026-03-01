# frozen_string_literal: true

require "spec_helper"

RSpec.describe "build_features.rb" do
  it "results CSVからfeaturesを作る" do
    Dir.mktmpdir("spec-features-") do |tmp|
      in_dir = File.join(tmp, "raw")
      out_dir = File.join(tmp, "features")
      raw_html_dir = File.join(tmp, "raw_html")
      ymd = "20260226"

      write_csv(
        File.join(in_dir, "girls_results_20260225.csv"),
        %w[race_date venue race_number racedetail_id show_result_url rank result_status frame_number car_number player_name age class raw_cells],
        [
          { "race_date" => "2026-02-25", "venue" => "toride", "race_number" => "1", "racedetail_id" => "2320260225020001", "show_result_url" => "u", "rank" => "1", "result_status" => "normal", "frame_number" => "", "car_number" => "1", "player_name" => "A", "age" => "", "class" => "", "raw_cells" => "◎ | 1 | 1 | A" },
          { "race_date" => "2026-02-25", "venue" => "toride", "race_number" => "1", "racedetail_id" => "2320260225020001", "show_result_url" => "u", "rank" => "2", "result_status" => "normal", "frame_number" => "", "car_number" => "2", "player_name" => "B", "age" => "", "class" => "", "raw_cells" => "○ | 2 | 2 | B" },
          { "race_date" => "2026-02-25", "venue" => "toride", "race_number" => "1", "racedetail_id" => "2320260225020001", "show_result_url" => "u", "rank" => "3", "result_status" => "normal", "frame_number" => "", "car_number" => "3", "player_name" => "C", "age" => "", "class" => "", "raw_cells" => "▲ | 3 | 3 | C" }
        ]
      )

      write_csv(
        File.join(in_dir, "girls_results_#{ymd}.csv"),
        %w[race_date venue race_number racedetail_id show_result_url rank result_status frame_number car_number player_name age class raw_cells],
        [
          { "race_date" => "2026-02-26", "venue" => "toride", "race_number" => "1", "racedetail_id" => "2320260225030001", "show_result_url" => "u", "rank" => "1", "result_status" => "normal", "frame_number" => "", "car_number" => "1", "player_name" => "A", "age" => "", "class" => "", "raw_cells" => "◎ | 1 | 1 | A" },
          { "race_date" => "2026-02-26", "venue" => "toride", "race_number" => "1", "racedetail_id" => "2320260225030001", "show_result_url" => "u", "rank" => "2", "result_status" => "normal", "frame_number" => "", "car_number" => "2", "player_name" => "B", "age" => "", "class" => "", "raw_cells" => "○ | 2 | 2 | B" },
          { "race_date" => "2026-02-26", "venue" => "toride", "race_number" => "1", "racedetail_id" => "2320260225030001", "show_result_url" => "u", "rank" => "3", "result_status" => "normal", "frame_number" => "", "car_number" => "3", "player_name" => "C", "age" => "", "class" => "", "raw_cells" => "▲ | 3 | 3 | C" }
        ]
      )

      _out, err, status = run_cmd(
        "ruby", "scripts/build_features.rb",
        "--from-date", "2026-02-25",
        "--to-date", "2026-02-26",
        "--in-dir", in_dir,
        "--out-dir", out_dir,
        "--raw-html-dir", raw_html_dir
      )
      expect(status.success?).to be(true), err

      rows = CSV.read(File.join(out_dir, "features_20260226.csv"), headers: true)
      expect(rows.size).to eq(3)
      expect(rows.first["top1"]).to eq("1")
      expect(rows.map { |r| r["top3"] }.uniq).to eq(["1"])
      expect(rows.first["hist_recent3_top3_rate"]).to eq("1.000000")
      expect(rows.first["mark_score"]).to eq("5.0")
      expect(rows.first["same_meet_prev_day_rank"]).to eq("1")
    end
  end

  it "入力CSVが見つからない場合はエラーになる" do
    Dir.mktmpdir("spec-features-missing-") do |tmp|
      _out, err, status = run_cmd(
        "ruby", "scripts/build_features.rb",
        "--from-date", "2026-02-25",
        "--to-date", "2026-02-25",
        "--in-dir", File.join(tmp, "raw"),
        "--out-dir", File.join(tmp, "features"),
        "--raw-html-dir", File.join(tmp, "raw_html")
      )
      expect(status.success?).to be(false)
      expect(err).to include("not found:")
    end
  end
end
