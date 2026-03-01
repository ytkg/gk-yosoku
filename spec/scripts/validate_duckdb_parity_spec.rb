# frozen_string_literal: true

require "spec_helper"

RSpec.describe "validate_duckdb_parity.rb" do
  it "CSV/Parquet parity レポートを生成する" do
    Dir.mktmpdir("spec-validate-duckdb-") do |tmp|
      bin_dir = File.join(tmp, "bin")
      create_fake_duckdb(bin_dir)
      env = { "PATH" => "#{bin_dir}:#{ENV.fetch('PATH', '')}" }

      csv_features_dir = File.join(tmp, "features")
      lake_dir = File.join(tmp, "lake")
      report_dir = File.join(tmp, "reports")
      db_path = File.join(tmp, "duckdb", "gk_yosoku.duckdb")
      ymd = "20260225"
      write_csv(
        File.join(csv_features_dir, "features_#{ymd}.csv"),
        %w[race_id car_number rank top1 top3],
        [{ "race_id" => "2026-02-25-toride-01", "car_number" => "1", "rank" => "1", "top1" => "1", "top3" => "1" }]
      )
      parquet_path = File.join(lake_dir, "features", "feature_set=v1", "race_date=2026-02-25", "features_#{ymd}.parquet")
      FileUtils.mkdir_p(File.dirname(parquet_path))
      File.write(parquet_path, "fake parquet")

      _out, err, st = run_cmd(
        "ruby", "scripts/validate_duckdb_parity.rb",
        "--from-date", "2026-02-25",
        "--to-date", "2026-02-25",
        "--csv-features-dir", csv_features_dir,
        "--lake-dir", lake_dir,
        "--report-dir", report_dir,
        "--db-path", db_path,
        env: env
      )
      expect(st.success?).to be(true), err
      report_root = Dir.glob(File.join(report_dir, "*")).find { |p| File.directory?(p) }
      expect(report_root).not_to be_nil
      expect(File).to exist(File.join(report_root, "summary.json"))
      expect(File).to exist(File.join(report_root, "2026-02-25", "summary.csv"))
      expect(File).to exist(File.join(report_root, "2026-02-25", "diff_samples.csv"))
    end
  end
end
