# frozen_string_literal: true

require "spec_helper"

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

  it "run_timeseries_cv.rbで複数foldの時系列CVを実行できる" do
    Dir.mktmpdir("spec-cv-") do |tmp|
      bin_dir = File.join(tmp, "bin")
      create_fake_lightgbm(bin_dir)
      env = { "PATH" => "#{bin_dir}:#{ENV.fetch('PATH', '')}" }

      features_dir = File.join(tmp, "features")
      out_dir = File.join(tmp, "cv")
      (Date.iso8601("2026-01-01")..Date.iso8601("2026-01-06")).each do |d|
        ymd = d.strftime("%Y%m%d")
        race_id = "#{d.iso8601}-toride-01"
        rows = sample_feature_rows(date: d.iso8601, race_id: race_id, racedetail_id: "2320260101010001")
        write_csv(File.join(features_dir, "features_#{ymd}.csv"), feature_headers, rows)
      end

      _out, err, st = run_cmd(
        "ruby", "scripts/run_timeseries_cv.rb",
        "--from-date", "2026-01-01",
        "--to-date", "2026-01-06",
        "--train-days", "2",
        "--valid-days", "2",
        "--step-days", "2",
        "--in-dir", features_dir,
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
        "--in-dir", File.join(tmp, "features"),
        "--out-dir", out_dir,
        "--target-col", "top3"
      )
      expect(st.success?).to be(false)
      expect(err).to include("no folds generated")
    end
  end
end
