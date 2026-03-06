# frozen_string_literal: true

require "spec_helper"
require_relative "../../scripts/lib/model_manifest"

RSpec.describe "exacta model scripts" do
  it "build_exacta_features.rbで順序ペア特徴量を作成できる" do
    Dir.mktmpdir("spec-exacta-build-") do |tmp|
      train_csv = File.join(tmp, "train.csv")
      valid_csv = File.join(tmp, "valid.csv")
      train_rows = sample_feature_rows(date: "2026-02-25", race_id: "2026-02-25-toride-01")
      valid_rows = sample_feature_rows(date: "2026-02-26", race_id: "2026-02-26-toride-01")
      write_csv(train_csv, feature_headers, train_rows)
      write_csv(valid_csv, feature_headers, valid_rows)

      out_dir = File.join(tmp, "ml_exacta")
      _out, err, st = run_cmd(
        "ruby", "scripts/build_exacta_features.rb",
        "--train-csv", train_csv,
        "--valid-csv", valid_csv,
        "--out-dir", out_dir
      )
      expect(st.success?).to be(true), err

      train_exacta = CSV.read(File.join(out_dir, "train.csv"), headers: true)
      valid_exacta = CSV.read(File.join(out_dir, "valid.csv"), headers: true)
      expect(train_exacta.size).to eq(6)
      expect(valid_exacta.size).to eq(6)
      expect(train_exacta.headers).to include("exacta_top1", "first_player_name", "second_player_name", "diff_hist_races")
      expect(train_exacta.count { |r| r["exacta_top1"] == "1" }).to eq(1)

      positive = train_exacta.find { |r| r["exacta_top1"] == "1" }
      expect(positive["first_car_number"]).to eq("1")
      expect(positive["second_car_number"]).to eq("2")
    end
  end

  it "build_exacta_features.rb: train/valid parquet指定でも実行できる" do
    Dir.mktmpdir("spec-exacta-build-parquet-") do |tmp|
      train_source_csv = File.join(tmp, "train_source.csv")
      valid_source_csv = File.join(tmp, "valid_source.csv")
      write_csv(train_source_csv, feature_headers, sample_feature_rows(date: "2026-02-25", race_id: "2026-02-25-toride-01"))
      write_csv(valid_source_csv, feature_headers, sample_feature_rows(date: "2026-02-26", race_id: "2026-02-26-toride-01"))

      bin_dir = File.join(tmp, "bin")
      create_fake_duckdb_for_exacta_parquet(bin_dir, train_source_csv, valid_source_csv)
      env = { "PATH" => "#{bin_dir}:#{ENV.fetch('PATH', '')}" }

      train_parquet = File.join(tmp, "train.parquet")
      valid_parquet = File.join(tmp, "valid.parquet")
      File.write(train_parquet, "fake parquet")
      File.write(valid_parquet, "fake parquet")

      out_dir = File.join(tmp, "ml_exacta")
      _out, err, st = run_cmd(
        "ruby", "scripts/build_exacta_features.rb",
        "--train-parquet", train_parquet,
        "--valid-parquet", valid_parquet,
        "--db-path", File.join(tmp, "duckdb", "gk_yosoku.duckdb"),
        "--out-dir", out_dir,
        env: env
      )
      expect(st.success?).to be(true), err
      expect(File).to exist(File.join(out_dir, "train_from_parquet.csv"))
      expect(File).to exist(File.join(out_dir, "valid_from_parquet.csv"))
      expect(File).to exist(File.join(out_dir, "train.csv"))
      expect(File).to exist(File.join(out_dir, "valid.csv"))
    end
  end

  it "train/evaluate exactaモデルをfake lightgbmで実行できる" do
    Dir.mktmpdir("spec-exacta-train-eval-") do |tmp|
      bin_dir = File.join(tmp, "bin")
      create_fake_lightgbm(bin_dir)
      env = { "PATH" => "#{bin_dir}:#{ENV.fetch('PATH', '')}" }

      train_csv = File.join(tmp, "train.csv")
      valid_csv = File.join(tmp, "valid.csv")
      train_rows = sample_feature_rows(date: "2026-02-25", race_id: "2026-02-25-toride-01")
      valid_rows = sample_feature_rows(date: "2026-02-26", race_id: "2026-02-26-toride-01")
      write_csv(train_csv, feature_headers, train_rows)
      write_csv(valid_csv, feature_headers, valid_rows)

      out_dir = File.join(tmp, "ml_exacta")
      _out1, err1, st1 = run_cmd(
        "ruby", "scripts/build_exacta_features.rb",
        "--train-csv", train_csv,
        "--valid-csv", valid_csv,
        "--out-dir", out_dir,
        env: env
      )
      expect(st1.success?).to be(true), err1

      _out2, err2, st2 = run_cmd(
        "ruby", "scripts/train_exacta_lightgbm.rb",
        "--train-csv", File.join(out_dir, "train.csv"),
        "--valid-csv", File.join(out_dir, "valid.csv"),
        "--out-dir", out_dir,
        env: env
      )
      expect(st2.success?).to be(true), err2
      expect(File).to exist(File.join(out_dir, "model.txt"))
      expect(File).to exist(File.join(out_dir, "encoders.json"))
      expect(File).to exist(File.join(out_dir, "feature_columns.json"))
      expect(File).to exist(File.join(out_dir, "categorical_features.json"))
      expect(File).to exist(File.join(out_dir, "model_manifest.json"))
      manifest = JSON.parse(File.read(File.join(out_dir, "model_manifest.json"), encoding: "UTF-8"))
      GK::ModelManifest::REQUIRED_KEYS.each do |key|
        expect(manifest).to have_key(key)
      end
      expect(manifest["data_source_mode"]).to eq("csv")

      _out3, err3, st3 = run_cmd(
        "ruby", "scripts/evaluate_exacta_lightgbm.rb",
        "--model", File.join(out_dir, "model.txt"),
        "--valid-csv", File.join(out_dir, "valid.csv"),
        "--encoders", File.join(out_dir, "encoders.json"),
        "--out-dir", out_dir,
        "--exacta-top", "3",
        "--ns", "1,3",
        env: env
      )
      expect(st3.success?).to be(true), err3

      summary = JSON.parse(File.read(File.join(out_dir, "eval_summary.json"), encoding: "UTF-8"))
      expect(summary["rows"]).to eq(6)
      expect(summary["races"]).to eq(1)
      expect(summary.dig("hit_at", "1")).to be >= 0.0
      expect(summary.dig("hit_at", "3")).to be >= 0.0

      exacta_pred = CSV.read(File.join(out_dir, "exacta_pred.csv"), headers: true)
      expect(exacta_pred.size).to eq(3)
    end
  end

  it "train_exacta_lightgbm.rb: train/valid parquet指定でも実行できる" do
    Dir.mktmpdir("spec-exacta-train-parquet-") do |tmp|
      bin_dir = File.join(tmp, "bin")
      create_fake_lightgbm(bin_dir)
      env = { "PATH" => "#{bin_dir}:#{ENV.fetch('PATH', '')}" }

      train_csv = File.join(tmp, "train.csv")
      valid_csv = File.join(tmp, "valid.csv")
      train_rows = sample_feature_rows(date: "2026-02-25", race_id: "2026-02-25-toride-01")
      valid_rows = sample_feature_rows(date: "2026-02-26", race_id: "2026-02-26-toride-01")
      write_csv(train_csv, feature_headers, train_rows)
      write_csv(valid_csv, feature_headers, valid_rows)

      out_dir = File.join(tmp, "ml_exacta")
      _out1, err1, st1 = run_cmd(
        "ruby", "scripts/build_exacta_features.rb",
        "--train-csv", train_csv,
        "--valid-csv", valid_csv,
        "--out-dir", out_dir,
        env: env
      )
      expect(st1.success?).to be(true), err1

      create_fake_duckdb_for_exacta_parquet(
        bin_dir,
        File.join(out_dir, "train.csv"),
        File.join(out_dir, "valid.csv")
      )

      train_parquet = File.join(tmp, "train.parquet")
      valid_parquet = File.join(tmp, "valid.parquet")
      File.write(train_parquet, "fake parquet")
      File.write(valid_parquet, "fake parquet")

      _out2, err2, st2 = run_cmd(
        "ruby", "scripts/train_exacta_lightgbm.rb",
        "--train-parquet", train_parquet,
        "--valid-parquet", valid_parquet,
        "--db-path", File.join(tmp, "duckdb", "gk_yosoku.duckdb"),
        "--out-dir", out_dir,
        env: env
      )
      expect(st2.success?).to be(true), err2
      expect(File).to exist(File.join(out_dir, "train_from_parquet.csv"))
      expect(File).to exist(File.join(out_dir, "valid_from_parquet.csv"))
      expect(File).to exist(File.join(out_dir, "model.txt"))
    end
  end

  it "evaluate_exacta_lightgbm.rb: valid-parquet指定でも実行できる" do
    Dir.mktmpdir("spec-exacta-eval-parquet-") do |tmp|
      bin_dir = File.join(tmp, "bin")
      create_fake_lightgbm(bin_dir)
      env = { "PATH" => "#{bin_dir}:#{ENV.fetch('PATH', '')}" }

      train_csv = File.join(tmp, "train.csv")
      valid_csv = File.join(tmp, "valid.csv")
      rows = sample_feature_rows(date: "2026-02-25", race_id: "2026-02-25-toride-01")
      write_csv(train_csv, feature_headers, rows)
      write_csv(valid_csv, feature_headers, rows)

      out_dir = File.join(tmp, "ml_exacta")
      _out1, err1, st1 = run_cmd(
        "ruby", "scripts/build_exacta_features.rb",
        "--train-csv", train_csv,
        "--valid-csv", valid_csv,
        "--out-dir", out_dir,
        env: env
      )
      expect(st1.success?).to be(true), err1

      _out2, err2, st2 = run_cmd(
        "ruby", "scripts/train_exacta_lightgbm.rb",
        "--train-csv", File.join(out_dir, "train.csv"),
        "--valid-csv", File.join(out_dir, "valid.csv"),
        "--out-dir", out_dir,
        env: env
      )
      expect(st2.success?).to be(true), err2

      create_fake_duckdb_for_exacta_parquet(
        bin_dir,
        File.join(out_dir, "train.csv"),
        File.join(out_dir, "valid.csv")
      )
      valid_parquet = File.join(tmp, "valid.parquet")
      File.write(valid_parquet, "fake parquet")

      _out3, err3, st3 = run_cmd(
        "ruby", "scripts/evaluate_exacta_lightgbm.rb",
        "--model", File.join(out_dir, "model.txt"),
        "--valid-parquet", valid_parquet,
        "--db-path", File.join(tmp, "duckdb", "gk_yosoku.duckdb"),
        "--encoders", File.join(out_dir, "encoders.json"),
        "--out-dir", out_dir,
        env: env
      )
      expect(st3.success?).to be(true), err3
      expect(File).to exist(File.join(out_dir, "valid_from_parquet.csv"))
      expect(File).to exist(File.join(out_dir, "eval_summary.json"))
    end
  end

  def create_fake_duckdb_for_exacta_parquet(bin_dir, train_source_csv, valid_source_csv)
    FileUtils.mkdir_p(bin_dir)
    path = File.join(bin_dir, "duckdb")
    File.write(path, <<~SCRIPT)
      #!/usr/bin/env ruby
      require "fileutils"

      sql = STDIN.read
      sql.scan(/TO\\s+'([^']+)'/i).flatten.each do |out_path|
        FileUtils.mkdir_p(File.dirname(out_path))
        if out_path.include?("train_from_parquet.csv")
          FileUtils.cp("#{train_source_csv}", out_path)
        elsif out_path.include?("valid_from_parquet.csv")
          FileUtils.cp("#{valid_source_csv}", out_path)
        elsif out_path.end_with?(".csv")
          File.write(out_path, "race_id,race_date,venue,race_number,car_number,player_name,rank,top1,top3\\n")
        elsif out_path.end_with?(".parquet")
          File.write(out_path, "fake parquet")
        end
      end
      puts "duckdb ok"
    SCRIPT
    FileUtils.chmod("u+x", path)
    path
  end

  it "train_exacta_lightgbm.rb: 不正なweight_modeはエラーになる" do
    Dir.mktmpdir("spec-exacta-invalid-weight-") do |tmp|
      bin_dir = File.join(tmp, "bin")
      create_fake_lightgbm(bin_dir)
      env = { "PATH" => "#{bin_dir}:#{ENV.fetch('PATH', '')}" }

      train_csv = File.join(tmp, "train.csv")
      valid_csv = File.join(tmp, "valid.csv")
      rows = sample_feature_rows(date: "2026-02-25", race_id: "2026-02-25-toride-01")
      write_csv(train_csv, feature_headers, rows)
      write_csv(valid_csv, feature_headers, rows)

      out_dir = File.join(tmp, "ml_exacta")
      _out1, err1, st1 = run_cmd(
        "ruby", "scripts/build_exacta_features.rb",
        "--train-csv", train_csv,
        "--valid-csv", valid_csv,
        "--out-dir", out_dir,
        env: env
      )
      expect(st1.success?).to be(true), err1

      _out2, err2, st2 = run_cmd(
        "ruby", "scripts/train_exacta_lightgbm.rb",
        "--train-csv", File.join(out_dir, "train.csv"),
        "--valid-csv", File.join(out_dir, "valid.csv"),
        "--out-dir", out_dir,
        "--weight-mode", "bad_mode",
        env: env
      )
      expect(st2.success?).to be(false)
      expect(err2).to include("invalid weight mode")
    end
  end

  it "train_exacta_lightgbm.rb: time_decay時はweight_column=1を設定する" do
    Dir.mktmpdir("spec-exacta-weight-col-") do |tmp|
      bin_dir = File.join(tmp, "bin")
      create_fake_lightgbm(bin_dir)
      env = { "PATH" => "#{bin_dir}:#{ENV.fetch('PATH', '')}" }

      train_csv = File.join(tmp, "train.csv")
      valid_csv = File.join(tmp, "valid.csv")
      rows = sample_feature_rows(date: "2026-02-25", race_id: "2026-02-25-toride-01")
      write_csv(train_csv, feature_headers, rows)
      write_csv(valid_csv, feature_headers, rows)

      out_dir = File.join(tmp, "ml_exacta")
      _out1, err1, st1 = run_cmd(
        "ruby", "scripts/build_exacta_features.rb",
        "--train-csv", train_csv,
        "--valid-csv", valid_csv,
        "--out-dir", out_dir,
        env: env
      )
      expect(st1.success?).to be(true), err1

      _out2, err2, st2 = run_cmd(
        "ruby", "scripts/train_exacta_lightgbm.rb",
        "--train-csv", File.join(out_dir, "train.csv"),
        "--valid-csv", File.join(out_dir, "valid.csv"),
        "--out-dir", out_dir,
        "--weight-mode", "time_decay",
        env: env
      )
      expect(st2.success?).to be(true), err2

      conf = File.read(File.join(out_dir, "lightgbm.conf"), encoding: "UTF-8")
      expect(conf).to include("weight_column=1")
      expect(conf).not_to include("weight_column=0")
    end
  end
end
