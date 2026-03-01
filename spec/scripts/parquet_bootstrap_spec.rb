# frozen_string_literal: true

require "spec_helper"

RSpec.describe "parquet_bootstrap.rb" do
  it "raw CSV から Parquet を生成する" do
    Dir.mktmpdir("spec-parquet-bootstrap-") do |tmp|
      bin_dir = File.join(tmp, "bin")
      create_fake_duckdb(bin_dir)
      env = { "PATH" => "#{bin_dir}:#{ENV.fetch('PATH', '')}" }

      in_dir = File.join(tmp, "raw")
      lake_dir = File.join(tmp, "lake")
      db_path = File.join(tmp, "duckdb", "gk_yosoku.duckdb")
      ymd = "20260225"

      write_csv(
        File.join(in_dir, "girls_results_#{ymd}.csv"),
        %w[race_date venue race_number racedetail_id show_result_url rank result_status frame_number car_number player_name age class raw_cells],
        [{ "race_date" => "2026-02-25", "venue" => "toride", "race_number" => "1", "racedetail_id" => "x", "show_result_url" => "u", "rank" => "1", "result_status" => "normal", "frame_number" => "1", "car_number" => "1", "player_name" => "A", "age" => "30", "class" => "L1", "raw_cells" => "" }]
      )
      write_csv(
        File.join(in_dir, "girls_races_#{ymd}.csv"),
        %w[race_date venue race_number show_result_url racedetail_id kaisai_start_date kaisai_day_no],
        [{ "race_date" => "2026-02-25", "venue" => "toride", "race_number" => "1", "show_result_url" => "u", "racedetail_id" => "x", "kaisai_start_date" => "2026-02-25", "kaisai_day_no" => "1" }]
      )

      _out, err, st = run_cmd(
        "ruby", "scripts/parquet_bootstrap.rb",
        "--from-date", "2026-02-25",
        "--to-date", "2026-02-25",
        "--in-dir", in_dir,
        "--lake-dir", lake_dir,
        "--db-path", db_path,
        env: env
      )
      expect(st.success?).to be(true), err
      expect(File).to exist(File.join(lake_dir, "raw_results", "race_date=2026-02-25", "results_#{ymd}.parquet"))
      expect(File).to exist(File.join(lake_dir, "races", "race_date=2026-02-25", "races_#{ymd}.parquet"))
    end
  end
end
