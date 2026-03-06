# frozen_string_literal: true

require "spec_helper"

RSpec.describe "split_features_duckdb.rb" do
  it "features Parquet から train/valid CSV と mart Parquet を生成する" do
    Dir.mktmpdir("spec-split-duckdb-") do |tmp|
      bin_dir = File.join(tmp, "bin")
      create_fake_duckdb(bin_dir)
      env = { "PATH" => "#{bin_dir}:#{ENV.fetch('PATH', '')}" }

      lake_dir = File.join(tmp, "lake")
      out_dir = File.join(tmp, "ml")
      mart_dir = File.join(tmp, "marts", "train_valid")
      db_path = File.join(tmp, "duckdb", "gk_yosoku.duckdb")
      parquet_path = File.join(lake_dir, "features", "feature_set=v1", "race_date=2026-02-25", "features_20260225.parquet")
      FileUtils.mkdir_p(File.dirname(parquet_path))
      File.write(parquet_path, "fake parquet")

      _out, err, st = run_cmd(
        "ruby", "scripts/split_features_duckdb.rb",
        "--from-date", "2026-02-25",
        "--to-date", "2026-02-26",
        "--train-to", "2026-02-25",
        "--lake-dir", lake_dir,
        "--out-dir", out_dir,
        "--mart-dir", mart_dir,
        "--db-path", db_path,
        env: env
      )
      expect(st.success?).to be(true), err
      expect(File).to exist(File.join(out_dir, "train.csv"))
      expect(File).to exist(File.join(out_dir, "valid.csv"))
      split_dir = File.join(mart_dir, "split_id=20260225_20260226_train_to_20260225")
      expect(File).to exist(File.join(split_dir, "train.parquet"))
      expect(File).to exist(File.join(split_dir, "valid.parquet"))
    end
  end

  it "--emit-csv false のとき CSV を生成しない" do
    Dir.mktmpdir("spec-split-duckdb-no-csv-") do |tmp|
      bin_dir = File.join(tmp, "bin")
      create_fake_duckdb(bin_dir)
      env = { "PATH" => "#{bin_dir}:#{ENV.fetch('PATH', '')}" }

      lake_dir = File.join(tmp, "lake")
      out_dir = File.join(tmp, "ml")
      mart_dir = File.join(tmp, "marts", "train_valid")
      db_path = File.join(tmp, "duckdb", "gk_yosoku.duckdb")
      parquet_path = File.join(lake_dir, "features", "feature_set=v1", "race_date=2026-02-25", "features_20260225.parquet")
      FileUtils.mkdir_p(File.dirname(parquet_path))
      File.write(parquet_path, "fake parquet")

      _out, err, st = run_cmd(
        "ruby", "scripts/split_features_duckdb.rb",
        "--from-date", "2026-02-25",
        "--to-date", "2026-02-26",
        "--train-to", "2026-02-25",
        "--lake-dir", lake_dir,
        "--out-dir", out_dir,
        "--mart-dir", mart_dir,
        "--db-path", db_path,
        "--emit-csv", "false",
        env: env
      )
      expect(st.success?).to be(true), err
      expect(File).not_to exist(File.join(out_dir, "train.csv"))
      expect(File).not_to exist(File.join(out_dir, "valid.csv"))
      split_dir = File.join(mart_dir, "split_id=20260225_20260226_train_to_20260225")
      expect(File).to exist(File.join(split_dir, "train.parquet"))
      expect(File).to exist(File.join(split_dir, "valid.parquet"))
    end
  end
end
