# frozen_string_literal: true

require "spec_helper"

RSpec.describe "evaluate_lightgbm_duckdb.rb" do
  it "Parquet -> valid CSV を経由して評価を実行できる" do
    Dir.mktmpdir("spec-eval-duckdb-") do |tmp|
      bin_dir = File.join(tmp, "bin")
      create_fake_duckdb(bin_dir)
      create_fake_lightgbm(bin_dir)
      env = { "PATH" => "#{bin_dir}:#{ENV.fetch('PATH', '')}" }

      lake_dir = File.join(tmp, "lake")
      out_dir = File.join(tmp, "ml")
      db_path = File.join(tmp, "duckdb", "gk_yosoku.duckdb")
      parquet_path = File.join(lake_dir, "features", "feature_set=v1", "race_date=2026-02-25", "features_20260225.parquet")
      FileUtils.mkdir_p(File.dirname(parquet_path))
      File.write(parquet_path, "fake parquet")

      FileUtils.mkdir_p(out_dir)
      File.write(File.join(out_dir, "model.txt"), "dummy")
      File.write(File.join(out_dir, "encoders.json"), "{}")

      _out, err, st = run_cmd(
        "ruby", "scripts/evaluate_lightgbm_duckdb.rb",
        "--from-date", "2026-02-25",
        "--to-date", "2026-02-25",
        "--model", File.join(out_dir, "model.txt"),
        "--encoders", File.join(out_dir, "encoders.json"),
        "--out-dir", out_dir,
        "--target-col", "top3",
        "--lake-dir", lake_dir,
        "--db-path", db_path,
        env: env
      )
      expect(st.success?).to be(true), err
      expect(File).to exist(File.join(out_dir, "valid_from_duckdb.csv"))
      expect(File).to exist(File.join(out_dir, "eval_summary.json"))
    end
  end
end
