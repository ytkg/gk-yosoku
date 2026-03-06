# frozen_string_literal: true

require "spec_helper"
require_relative "../../scripts/lib/model_manifest"

RSpec.describe "train/eval/tune/run_timeseries_cv" do
  it "fake lightgbmでtrain/eval/tuneを実行できる" do
    Dir.mktmpdir("spec-ml-") do |tmp|
      bin_dir = File.join(tmp, "bin")
      create_fake_lightgbm(bin_dir)
      env = { "PATH" => "#{bin_dir}:#{ENV.fetch('PATH', '')}" }

      train_csv = File.join(tmp, "train.csv")
      valid_csv = File.join(tmp, "valid.csv")
      train_rows = sample_feature_rows(date: "2026-02-25", race_id: "2026-02-25-toride-01")
      valid_rows = sample_feature_rows(date: "2026-02-26", race_id: "2026-02-26-toride-01")
      write_csv(train_csv, feature_headers, train_rows)
      write_csv(valid_csv, feature_headers, valid_rows)

      out_dir = File.join(tmp, "ml")
      _out1, err1, st1 = run_cmd(
        "ruby", "scripts/train_lightgbm.rb",
        "--train-csv", train_csv,
        "--valid-csv", valid_csv,
        "--out-dir", out_dir,
        env: env
      )
      expect(st1.success?).to be(true), err1
      expect(File).to exist(File.join(out_dir, "model.txt"))
      expect(File).to exist(File.join(out_dir, "encoders.json"))
      expect(File).to exist(File.join(out_dir, "model_manifest.json"))
      manifest = JSON.parse(File.read(File.join(out_dir, "model_manifest.json"), encoding: "UTF-8"))
      GK::ModelManifest::REQUIRED_KEYS.each do |key|
        expect(manifest).to have_key(key)
      end
      expect(manifest["data_source_mode"]).to eq("csv")

      _out2, err2, st2 = run_cmd(
        "ruby", "scripts/evaluate_lightgbm.rb",
        "--model", File.join(out_dir, "model.txt"),
        "--valid-csv", valid_csv,
        "--encoders", File.join(out_dir, "encoders.json"),
        "--out-dir", out_dir,
        env: env
      )
      expect(st2.success?).to be(true), err2
      summary = JSON.parse(File.read(File.join(out_dir, "eval_summary.json"), encoding: "UTF-8"))
      expect(summary["rows"]).to eq(3)

      tune_out = File.join(tmp, "tuning")
      _out3, err3, st3 = run_cmd(
        "ruby", "scripts/tune_lightgbm.rb",
        "--train-csv", train_csv,
        "--valid-csv", valid_csv,
        "--out-dir", tune_out,
        "--num-iterations", "5",
        "--learning-rates", "0.03",
        "--num-leaves", "31",
        "--min-data-in-leaf", "20",
        env: env
      )
      expect(st3.success?).to be(true), err3
      lb = CSV.read(File.join(tune_out, "tune_leaderboard.csv"), headers: true)
      expect(lb.size).to eq(1)
      expect(File).to exist(File.join(tune_out, "best_params.json"))
    end
  end

  it "tune_lightgbm.rb: valid-parquet指定でも実行できる" do
    Dir.mktmpdir("spec-tune-parquet-") do |tmp|
      bin_dir = File.join(tmp, "bin")
      create_fake_lightgbm(bin_dir)
      create_fake_duckdb(bin_dir)
      env = { "PATH" => "#{bin_dir}:#{ENV.fetch('PATH', '')}" }

      train_csv = File.join(tmp, "train.csv")
      valid_csv = File.join(tmp, "valid.csv")
      train_rows = sample_feature_rows(date: "2026-02-25", race_id: "2026-02-25-toride-01")
      valid_rows = sample_feature_rows(date: "2026-02-26", race_id: "2026-02-26-toride-01")
      write_csv(train_csv, feature_headers, train_rows)
      write_csv(valid_csv, feature_headers, valid_rows)

      valid_parquet = File.join(tmp, "valid.parquet")
      File.write(valid_parquet, "fake parquet")
      out_dir = File.join(tmp, "tuning")
      _out, err, st = run_cmd(
        "ruby", "scripts/tune_lightgbm.rb",
        "--train-csv", train_csv,
        "--valid-csv", valid_csv,
        "--valid-parquet", valid_parquet,
        "--db-path", File.join(tmp, "duckdb", "gk_yosoku.duckdb"),
        "--out-dir", out_dir,
        "--num-iterations", "5",
        "--learning-rates", "0.03",
        "--num-leaves", "31",
        "--min-data-in-leaf", "20",
        env: env
      )
      expect(st.success?).to be(true), err
      lb = CSV.read(File.join(out_dir, "tune_leaderboard.csv"), headers: true)
      expect(lb.size).to eq(1)
      expect(File).to exist(File.join(out_dir, "best_params.json"))
    end
  end

  it "train_lightgbm.rb: train/valid parquet指定でも実行できる" do
    Dir.mktmpdir("spec-train-parquet-") do |tmp|
      bin_dir = File.join(tmp, "bin")
      create_fake_lightgbm(bin_dir)
      create_fake_duckdb(bin_dir)
      env = { "PATH" => "#{bin_dir}:#{ENV.fetch('PATH', '')}" }

      train_parquet = File.join(tmp, "train.parquet")
      valid_parquet = File.join(tmp, "valid.parquet")
      File.write(train_parquet, "fake parquet")
      File.write(valid_parquet, "fake parquet")

      out_dir = File.join(tmp, "ml")
      _out, err, st = run_cmd(
        "ruby", "scripts/train_lightgbm.rb",
        "--train-parquet", train_parquet,
        "--valid-parquet", valid_parquet,
        "--db-path", File.join(tmp, "duckdb", "gk_yosoku.duckdb"),
        "--out-dir", out_dir,
        env: env
      )
      expect(st.success?).to be(true), err
      expect(File).to exist(File.join(out_dir, "train_from_parquet.csv"))
      expect(File).to exist(File.join(out_dir, "valid_from_parquet.csv"))
      expect(File).to exist(File.join(out_dir, "model.txt"))
      expect(File).to exist(File.join(out_dir, "model_manifest.json"))
    end
  end

  it "train_lightgbm.rb: parquet片側指定はエラーになる" do
    Dir.mktmpdir("spec-train-parquet-invalid-") do |tmp|
      bin_dir = File.join(tmp, "bin")
      create_fake_lightgbm(bin_dir)
      create_fake_duckdb(bin_dir)
      env = { "PATH" => "#{bin_dir}:#{ENV.fetch('PATH', '')}" }

      train_parquet = File.join(tmp, "train.parquet")
      File.write(train_parquet, "fake parquet")
      out_dir = File.join(tmp, "ml")
      _out, err, st = run_cmd(
        "ruby", "scripts/train_lightgbm.rb",
        "--train-parquet", train_parquet,
        "--out-dir", out_dir,
        env: env
      )
      expect(st.success?).to be(false)
      expect(err).to include("valid-parquet is required when train-parquet is set")
    end
  end

  it "train_lightgbm.rb: parquet指定時はcsv指定よりparquetを優先する" do
    Dir.mktmpdir("spec-train-parquet-priority-") do |tmp|
      bin_dir = File.join(tmp, "bin")
      create_fake_lightgbm(bin_dir)
      create_fake_duckdb(bin_dir)
      env = { "PATH" => "#{bin_dir}:#{ENV.fetch('PATH', '')}" }

      train_csv = File.join(tmp, "train.csv")
      valid_csv = File.join(tmp, "valid.csv")
      train_rows = sample_feature_rows(date: "2026-02-25", race_id: "2026-02-25-toride-01")
      valid_rows = sample_feature_rows(date: "2026-02-26", race_id: "2026-02-26-toride-01")
      write_csv(train_csv, feature_headers, train_rows)
      write_csv(valid_csv, feature_headers, valid_rows)

      train_parquet = File.join(tmp, "train.parquet")
      valid_parquet = File.join(tmp, "valid.parquet")
      File.write(train_parquet, "fake parquet")
      File.write(valid_parquet, "fake parquet")

      out_dir = File.join(tmp, "ml")
      _out, err, st = run_cmd(
        "ruby", "scripts/train_lightgbm.rb",
        "--train-csv", train_csv,
        "--valid-csv", valid_csv,
        "--train-parquet", train_parquet,
        "--valid-parquet", valid_parquet,
        "--db-path", File.join(tmp, "duckdb", "gk_yosoku.duckdb"),
        "--out-dir", out_dir,
        env: env
      )
      expect(st.success?).to be(true), err
      expect(err).to include("train-csv is ignored because train-parquet is set")
      expect(err).to include("valid-csv is ignored because valid-parquet is set")
      expect(err).to include("input_mode=parquet (train_lightgbm)")
    end
  end

  it "tune_lightgbm.rb: train/valid parquet指定でも実行できる" do
    Dir.mktmpdir("spec-tune-train-parquet-") do |tmp|
      bin_dir = File.join(tmp, "bin")
      create_fake_lightgbm(bin_dir)
      create_fake_duckdb(bin_dir)
      env = { "PATH" => "#{bin_dir}:#{ENV.fetch('PATH', '')}" }

      train_parquet = File.join(tmp, "train.parquet")
      valid_parquet = File.join(tmp, "valid.parquet")
      File.write(train_parquet, "fake parquet")
      File.write(valid_parquet, "fake parquet")

      out_dir = File.join(tmp, "tuning")
      _out, err, st = run_cmd(
        "ruby", "scripts/tune_lightgbm.rb",
        "--train-parquet", train_parquet,
        "--valid-parquet", valid_parquet,
        "--db-path", File.join(tmp, "duckdb", "gk_yosoku.duckdb"),
        "--out-dir", out_dir,
        "--num-iterations", "5",
        "--learning-rates", "0.03",
        "--num-leaves", "31",
        "--min-data-in-leaf", "20",
        env: env
      )
      expect(st.success?).to be(true), err
      lb = CSV.read(File.join(out_dir, "tune_leaderboard.csv"), headers: true)
      expect(lb.size).to eq(1)
      expect(File).to exist(File.join(out_dir, "best_params.json"))
    end
  end

  it "tune_lightgbm.rb: train-parquetのみ指定はエラーになる" do
    Dir.mktmpdir("spec-tune-parquet-invalid-") do |tmp|
      bin_dir = File.join(tmp, "bin")
      create_fake_lightgbm(bin_dir)
      create_fake_duckdb(bin_dir)
      env = { "PATH" => "#{bin_dir}:#{ENV.fetch('PATH', '')}" }

      train_parquet = File.join(tmp, "train.parquet")
      File.write(train_parquet, "fake parquet")
      out_dir = File.join(tmp, "tuning")
      _out, err, st = run_cmd(
        "ruby", "scripts/tune_lightgbm.rb",
        "--train-parquet", train_parquet,
        "--out-dir", out_dir,
        "--num-iterations", "5",
        "--learning-rates", "0.03",
        "--num-leaves", "31",
        "--min-data-in-leaf", "20",
        env: env
      )
      expect(st.success?).to be(false)
      expect(err).to include("valid-parquet is required when train-parquet is set")
    end
  end

  it "tune_lightgbm.rb: parquet指定時はcsv指定よりparquetを優先する" do
    Dir.mktmpdir("spec-tune-parquet-priority-") do |tmp|
      bin_dir = File.join(tmp, "bin")
      create_fake_lightgbm(bin_dir)
      create_fake_duckdb(bin_dir)
      env = { "PATH" => "#{bin_dir}:#{ENV.fetch('PATH', '')}" }

      train_csv = File.join(tmp, "train.csv")
      valid_csv = File.join(tmp, "valid.csv")
      train_rows = sample_feature_rows(date: "2026-02-25", race_id: "2026-02-25-toride-01")
      valid_rows = sample_feature_rows(date: "2026-02-26", race_id: "2026-02-26-toride-01")
      write_csv(train_csv, feature_headers, train_rows)
      write_csv(valid_csv, feature_headers, valid_rows)

      train_parquet = File.join(tmp, "train.parquet")
      valid_parquet = File.join(tmp, "valid.parquet")
      File.write(train_parquet, "fake parquet")
      File.write(valid_parquet, "fake parquet")

      out_dir = File.join(tmp, "tuning")
      _out, err, st = run_cmd(
        "ruby", "scripts/tune_lightgbm.rb",
        "--train-csv", train_csv,
        "--valid-csv", valid_csv,
        "--train-parquet", train_parquet,
        "--valid-parquet", valid_parquet,
        "--db-path", File.join(tmp, "duckdb", "gk_yosoku.duckdb"),
        "--out-dir", out_dir,
        "--num-iterations", "5",
        "--learning-rates", "0.03",
        "--num-leaves", "31",
        "--min-data-in-leaf", "20",
        env: env
      )
      expect(st.success?).to be(true), err
      expect(err).to include("train-csv is ignored because train-parquet is set")
      expect(err).to include("valid-csv is ignored because valid-parquet is set")
    end
  end

  it "evaluate_lightgbm.rb: valid-parquet指定でも評価できる" do
    Dir.mktmpdir("spec-eval-parquet-") do |tmp|
      bin_dir = File.join(tmp, "bin")
      create_fake_lightgbm(bin_dir)
      create_fake_duckdb(bin_dir)
      env = { "PATH" => "#{bin_dir}:#{ENV.fetch('PATH', '')}" }

      out_dir = File.join(tmp, "ml")
      FileUtils.mkdir_p(out_dir)
      File.write(File.join(out_dir, "model.txt"), "dummy")
      File.write(File.join(out_dir, "encoders.json"), "{}")
      valid_parquet = File.join(tmp, "valid.parquet")
      File.write(valid_parquet, "fake parquet")

      _out, err, st = run_cmd(
        "ruby", "scripts/evaluate_lightgbm.rb",
        "--model", File.join(out_dir, "model.txt"),
        "--encoders", File.join(out_dir, "encoders.json"),
        "--valid-parquet", valid_parquet,
        "--db-path", File.join(tmp, "duckdb", "gk_yosoku.duckdb"),
        "--out-dir", out_dir,
        env: env
      )
      expect(st.success?).to be(true), err
      expect(File).to exist(File.join(out_dir, "valid_from_parquet.csv"))
      expect(File).to exist(File.join(out_dir, "eval_summary.json"))
    end
  end

  it "run_timeseries_cv.rbで複数foldの時系列CVを実行できる" do
    Dir.mktmpdir("spec-cv-") do |tmp|
      bin_dir = File.join(tmp, "bin")
      create_fake_lightgbm(bin_dir)
      create_fake_duckdb(bin_dir)
      env = { "PATH" => "#{bin_dir}:#{ENV.fetch('PATH', '')}" }

      lake_dir = File.join(tmp, "lake")
      db_path = File.join(tmp, "duckdb", "gk_yosoku.duckdb")
      out_dir = File.join(tmp, "cv")
      (Date.iso8601("2026-01-01")..Date.iso8601("2026-01-06")).each do |d|
        ymd = d.strftime("%Y%m%d")
        parquet_path = File.join(
          lake_dir,
          "features",
          "feature_set=v1",
          "race_date=#{d.iso8601}",
          "features_#{ymd}.parquet"
        )
        FileUtils.mkdir_p(File.dirname(parquet_path))
        File.write(parquet_path, "fake parquet")
      end

      _out, err, st = run_cmd(
        "ruby", "scripts/run_timeseries_cv.rb",
        "--from-date", "2026-01-01",
        "--to-date", "2026-01-06",
        "--train-days", "2",
        "--valid-days", "2",
        "--step-days", "2",
        "--lake-dir", lake_dir,
        "--db-path", db_path,
        "--feature-set-version", "v1",
        "--out-dir", out_dir,
        "--target-col", "top3",
        env: env
      )
      expect(st.success?).to be(true), err

      results = CSV.read(File.join(out_dir, "cv_results.csv"), headers: true)
      summary = JSON.parse(File.read(File.join(out_dir, "cv_summary.json"), encoding: "UTF-8"))
      expect(results.size).to eq(2)
      expect(summary["folds"]).to eq(2)
      expect(summary["target_col"]).to eq("top3")
    end
  end

  it "train_lightgbm.rb: 不正なweight_modeはエラーになる" do
    Dir.mktmpdir("spec-train-invalid-weight-") do |tmp|
      bin_dir = File.join(tmp, "bin")
      create_fake_lightgbm(bin_dir)
      env = { "PATH" => "#{bin_dir}:#{ENV.fetch('PATH', '')}" }

      train_csv = File.join(tmp, "train.csv")
      valid_csv = File.join(tmp, "valid.csv")
      rows = sample_feature_rows(date: "2026-02-25", race_id: "2026-02-25-toride-01")
      write_csv(train_csv, feature_headers, rows)
      write_csv(valid_csv, feature_headers, rows)

      _out, err, st = run_cmd(
        "ruby", "scripts/train_lightgbm.rb",
        "--train-csv", train_csv,
        "--valid-csv", valid_csv,
        "--out-dir", File.join(tmp, "ml"),
        "--weight-mode", "bad_mode",
        env: env
      )
      expect(st.success?).to be(false)
      expect(err).to include("invalid weight mode")
    end
  end

  it "train_lightgbm.rb: time_decay時はweight_column=1を設定する" do
    Dir.mktmpdir("spec-train-weight-col-") do |tmp|
      bin_dir = File.join(tmp, "bin")
      create_fake_lightgbm(bin_dir)
      env = { "PATH" => "#{bin_dir}:#{ENV.fetch('PATH', '')}" }

      train_csv = File.join(tmp, "train.csv")
      valid_csv = File.join(tmp, "valid.csv")
      train_rows = sample_feature_rows(date: "2026-02-25", race_id: "2026-02-25-toride-01")
      valid_rows = sample_feature_rows(date: "2026-02-26", race_id: "2026-02-26-toride-01")
      write_csv(train_csv, feature_headers, train_rows)
      write_csv(valid_csv, feature_headers, valid_rows)

      out_dir = File.join(tmp, "ml")
      _out, err, st = run_cmd(
        "ruby", "scripts/train_lightgbm.rb",
        "--train-csv", train_csv,
        "--valid-csv", valid_csv,
        "--out-dir", out_dir,
        "--weight-mode", "time_decay",
        env: env
      )
      expect(st.success?).to be(true), err

      conf = File.read(File.join(out_dir, "lightgbm.conf"), encoding: "UTF-8")
      expect(conf).to include("weight_column=1")
      expect(conf).not_to include("weight_column=0")
    end
  end

  it "run_timeseries_cv.rb: foldが作れない期間設定はエラーになる" do
    Dir.mktmpdir("spec-cv-no-fold-") do |tmp|
      out_dir = File.join(tmp, "cv")
      _out, err, st = run_cmd(
        "ruby", "scripts/run_timeseries_cv.rb",
        "--from-date", "2026-01-01",
        "--to-date", "2026-01-02",
        "--train-days", "10",
        "--valid-days", "5",
        "--step-days", "1",
        "--lake-dir", File.join(tmp, "lake"),
        "--out-dir", out_dir,
        "--target-col", "top3"
      )
      expect(st.success?).to be(false)
      expect(err).to include("no folds generated")
    end
  end

  it "run_timeseries_cv.rb: parquet未生成時はエラーにする" do
    Dir.mktmpdir("spec-cv-csv-fallback-") do |tmp|
      bin_dir = File.join(tmp, "bin")
      create_fake_lightgbm(bin_dir)
      create_fake_duckdb_csv_only(bin_dir)
      env = { "PATH" => "#{bin_dir}:#{ENV.fetch('PATH', '')}" }

      lake_dir = File.join(tmp, "lake")
      db_path = File.join(tmp, "duckdb", "gk_yosoku.duckdb")
      out_dir = File.join(tmp, "cv")
      (Date.iso8601("2026-01-01")..Date.iso8601("2026-01-04")).each do |d|
        ymd = d.strftime("%Y%m%d")
        parquet_path = File.join(
          lake_dir,
          "features",
          "feature_set=v1",
          "race_date=#{d.iso8601}",
          "features_#{ymd}.parquet"
        )
        FileUtils.mkdir_p(File.dirname(parquet_path))
        File.write(parquet_path, "fake parquet")
      end

      _out, err, st = run_cmd(
        "ruby", "scripts/run_timeseries_cv.rb",
        "--from-date", "2026-01-01",
        "--to-date", "2026-01-04",
        "--train-days", "2",
        "--valid-days", "2",
        "--step-days", "2",
        "--lake-dir", lake_dir,
        "--db-path", db_path,
        "--feature-set-version", "v1",
        "--out-dir", out_dir,
        "--target-col", "top3",
        env: env
      )
      expect(st.success?).to be(false)
      expect(err).to include("split parquet outputs are required for cv train")
    end
  end

  def create_fake_duckdb_csv_only(bin_dir)
    FileUtils.mkdir_p(bin_dir)
    path = File.join(bin_dir, "duckdb")
    File.write(path, <<~'SCRIPT')
      #!/usr/bin/env ruby
      require "fileutils"

      sql = STDIN.read
      sql.scan(/TO\s+'([^']+)'/i).flatten.each do |out_path|
        FileUtils.mkdir_p(File.dirname(out_path))
        next if out_path.end_with?(".parquet")

        if out_path.end_with?("summary.csv")
          File.write(out_path, "csv_rows,parquet_rows,csv_only_keys,parquet_only_keys,rank_diff,top1_diff,top3_diff\n1,1,0,0,0,0,0\n")
        elsif out_path.end_with?(".csv")
          File.write(out_path, "race_id,race_date,venue,race_number,car_number,player_name,rank,top1,top3,mark_symbol,leg_style\nr1,2026-02-25,toride,1,1,A,1,1,1,◎,逃\n")
        end
      end
      puts "duckdb ok"
    SCRIPT
    FileUtils.chmod("u+x", path)
    path
  end
end
