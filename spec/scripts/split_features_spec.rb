# frozen_string_literal: true

require "spec_helper"

RSpec.describe "split_features.rb" do
  it "train/validに分割する" do
    Dir.mktmpdir("spec-split-") do |tmp|
      in_dir = File.join(tmp, "features")
      out_dir = File.join(tmp, "ml")
      headers = %w[race_id race_date value]
      write_csv(File.join(in_dir, "features_20260225.csv"), headers, [{ "race_id" => "r1", "race_date" => "2026-02-25", "value" => "a" }])
      write_csv(File.join(in_dir, "features_20260226.csv"), headers, [{ "race_id" => "r2", "race_date" => "2026-02-26", "value" => "b" }])

      _out, err, status = run_cmd(
        "ruby", "scripts/split_features.rb",
        "--from-date", "2026-02-25",
        "--to-date", "2026-02-26",
        "--train-to", "2026-02-25",
        "--in-dir", in_dir,
        "--out-dir", out_dir
      )
      expect(status.success?).to be(true), err

      train = CSV.read(File.join(out_dir, "train.csv"), headers: true)
      valid = CSV.read(File.join(out_dir, "valid.csv"), headers: true)
      expect(train.size).to eq(1)
      expect(valid.size).to eq(1)
      expect(train.first["race_id"]).to eq("r1")
      expect(valid.first["race_id"]).to eq("r2")
    end
  end

  it "train-to が範囲外ならエラーになる" do
    Dir.mktmpdir("spec-split-invalid-") do |tmp|
      in_dir = File.join(tmp, "features")
      out_dir = File.join(tmp, "ml")
      headers = %w[race_id race_date value]
      write_csv(File.join(in_dir, "features_20260225.csv"), headers, [{ "race_id" => "r1", "race_date" => "2026-02-25", "value" => "a" }])
      write_csv(File.join(in_dir, "features_20260226.csv"), headers, [{ "race_id" => "r2", "race_date" => "2026-02-26", "value" => "b" }])

      _out, err, status = run_cmd(
        "ruby", "scripts/split_features.rb",
        "--from-date", "2026-02-25",
        "--to-date", "2026-02-26",
        "--train-to", "2026-02-26",
        "--in-dir", in_dir,
        "--out-dir", out_dir
      )
      expect(status.success?).to be(false)
      expect(err).to include("train_to must be within from_date..to_date")
    end
  end
end
