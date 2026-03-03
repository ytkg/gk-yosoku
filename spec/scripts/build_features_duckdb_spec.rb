# frozen_string_literal: true

require "spec_helper"

RSpec.describe "build_features_duckdb.rb" do
  it "sql_v1モードでraw_results Parquetからfeaturesを生成する" do
    Dir.mktmpdir("spec-features-duckdb-") do |tmp|
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
        env: env
      )
      expect(st.success?).to be(true), err
      expect(File).to exist(File.join(out_dir, "features_20260225.csv"))
      expect(File).to exist(File.join(lake_dir, "features", "feature_set=v1", "race_date=2026-02-25", "features_20260225.parquet"))
    end
  end

  it "外部テンプレート指定でもstaging + features SQLを連結実行できる" do
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

      sql_template = File.join(tmp, "features.sql")
      staging_template = File.join(tmp, "staging.sql")
      File.write(sql_template, "COPY (SELECT 1 AS x FROM staging_raw_results LIMIT 1) TO '{{out_csv}}' (HEADER, DELIMITER ',');")
      File.write(staging_template, "CREATE OR REPLACE TEMP VIEW staging_raw_results AS SELECT * FROM read_parquet('{{raw_results_glob}}');")

      _out, err, st = run_cmd(
        "ruby", "scripts/build_features_duckdb.rb",
        "--from-date", "2026-02-25",
        "--to-date", "2026-02-25",
        "--out-dir", out_dir,
        "--lake-dir", lake_dir,
        "--db-path", db_path,
        "--feature-set-version", "v1",
        "--sql-template", sql_template,
        "--staging-sql-template", staging_template,
        env: env
      )
      expect(st.success?).to be(true), err
      expect(File).to exist(File.join(out_dir, "features_20260225.csv"))
      expect(File).to exist(File.join(lake_dir, "features", "feature_set=v1", "race_date=2026-02-25", "features_20260225.parquet"))
    end
  end
end
