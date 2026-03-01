# frozen_string_literal: true

require "spec_helper"

RSpec.describe "build_features_duckdb.rb" do
  it "--skip-build で features CSV を Parquet 化する" do
    Dir.mktmpdir("spec-features-duckdb-") do |tmp|
      bin_dir = File.join(tmp, "bin")
      create_fake_duckdb(bin_dir)
      env = { "PATH" => "#{bin_dir}:#{ENV.fetch('PATH', '')}" }

      out_dir = File.join(tmp, "features")
      lake_dir = File.join(tmp, "lake")
      db_path = File.join(tmp, "duckdb", "gk_yosoku.duckdb")
      ymd = "20260225"
      write_csv(
        File.join(out_dir, "features_#{ymd}.csv"),
        %w[race_id race_date car_number top1 top3],
        [{ "race_id" => "2026-02-25-toride-01", "race_date" => "2026-02-25", "car_number" => "1", "top1" => "1", "top3" => "1" }]
      )

      _out, err, st = run_cmd(
        "ruby", "scripts/build_features_duckdb.rb",
        "--from-date", "2026-02-25",
        "--to-date", "2026-02-25",
        "--out-dir", out_dir,
        "--lake-dir", lake_dir,
        "--db-path", db_path,
        "--feature-set-version", "v1",
        "--skip-build",
        env: env
      )
      expect(st.success?).to be(true), err
      expect(File).to exist(File.join(lake_dir, "features", "feature_set=v1", "race_date=2026-02-25", "features_#{ymd}.parquet"))
    end
  end

  it "sql_v1モードでraw_results Parquetからfeaturesを生成する" do
    Dir.mktmpdir("spec-features-duckdb-sql-") do |tmp|
      bin_dir = File.join(tmp, "bin")
      create_fake_duckdb(bin_dir)
      env = { "PATH" => "#{bin_dir}:#{ENV.fetch('PATH', '')}" }

      out_dir = File.join(tmp, "features")
      lake_dir = File.join(tmp, "lake")
      db_path = File.join(tmp, "duckdb", "gk_yosoku.duckdb")
      raw_path = File.join(lake_dir, "raw_results", "race_date=2026-02-25", "results_20260225.parquet")
      FileUtils.mkdir_p(File.dirname(raw_path))
      File.write(raw_path, "fake raw parquet")

      _out, err, st = run_cmd(
        "ruby", "scripts/build_features_duckdb.rb",
        "--from-date", "2026-02-25",
        "--to-date", "2026-02-25",
        "--out-dir", out_dir,
        "--lake-dir", lake_dir,
        "--db-path", db_path,
        "--feature-set-version", "v1",
        "--mode", "sql_v1",
        env: env
      )
      expect(st.success?).to be(true), err
      expect(File).to exist(File.join(out_dir, "features_20260225.csv"))
      expect(File).to exist(File.join(lake_dir, "features", "feature_set=v1", "race_date=2026-02-25", "features_20260225.parquet"))
    end
  end
end
