# frozen_string_literal: true

require "spec_helper"

RSpec.describe "generate/evaluate/learn exotics" do
  it "候補生成とhit@N評価" do
    Dir.mktmpdir("spec-exotic-") do |tmp|
      in_csv = File.join(tmp, "valid_pred.csv")
      win_csv = File.join(tmp, "valid_pred_top1.csv")
      out_dir = File.join(tmp, "ml")

      headers = %w[race_id race_date venue race_number car_number player_name rank top1 top3 score]
      rows_top3 = [
        { "race_id" => "r1", "race_date" => "2026-02-26", "venue" => "toride", "race_number" => "1", "car_number" => "1", "player_name" => "A", "rank" => "1", "top1" => "1", "top3" => "1", "score" => "0.9" },
        { "race_id" => "r1", "race_date" => "2026-02-26", "venue" => "toride", "race_number" => "1", "car_number" => "2", "player_name" => "B", "rank" => "2", "top1" => "0", "top3" => "1", "score" => "0.8" },
        { "race_id" => "r1", "race_date" => "2026-02-26", "venue" => "toride", "race_number" => "1", "car_number" => "3", "player_name" => "C", "rank" => "3", "top1" => "0", "top3" => "1", "score" => "0.7" }
      ]
      rows_top1 = rows_top3.each_with_index.map { |r, i| r.merge("score" => format("%.1f", 0.9 - i * 0.1)) }
      write_csv(in_csv, headers, rows_top3)
      write_csv(win_csv, headers, rows_top1)

      _out1, err1, st1 = run_cmd(
        "ruby", "scripts/generate_exotics.rb",
        "--in-csv", in_csv,
        "--win-csv", win_csv,
        "--out-dir", out_dir,
        "--exacta-top", "2",
        "--trifecta-top", "3"
      )
      expect(st1.success?).to be(true), err1
      exacta = CSV.read(File.join(out_dir, "exacta_pred.csv"), headers: true)
      trifecta = CSV.read(File.join(out_dir, "trifecta_pred.csv"), headers: true)
      expect(exacta.size).to eq(2)
      expect(trifecta.size).to eq(3)

      actual_csv = File.join(tmp, "valid.csv")
      write_csv(actual_csv, headers, rows_top3)
      summary_path = File.join(out_dir, "exotic_eval_summary.json")
      _out2, err2, st2 = run_cmd(
        "ruby", "scripts/evaluate_exotics.rb",
        "--actual-csv", actual_csv,
        "--exacta-csv", File.join(out_dir, "exacta_pred.csv"),
        "--trifecta-csv", File.join(out_dir, "trifecta_pred.csv"),
        "--out", summary_path,
        "--ns", "1,2,3"
      )
      expect(st2.success?).to be(true), err2
      summary = JSON.parse(File.read(summary_path, encoding: "UTF-8"))
      expect(summary["races"]).to eq(1)
      expect(summary["exacta"]["hit_at"].keys).to include("1", "2", "3")
    end
  end

  it "hit@5向けプロファイルを学習しgenerate_exoticsで利用できる" do
    Dir.mktmpdir("spec-exotic-profile-") do |tmp|
      train_top3_csv = File.join(tmp, "train_top3.csv")
      train_top1_csv = File.join(tmp, "train_top1.csv")
      valid_top3_csv = File.join(tmp, "valid_top3.csv")
      valid_top1_csv = File.join(tmp, "valid_top1.csv")
      train_actual_csv = File.join(tmp, "train_actual.csv")
      valid_actual_csv = File.join(tmp, "valid_actual.csv")
      out_dir = File.join(tmp, "out")
      profile_path = File.join(tmp, "exotic_profile.json")

      headers = %w[race_id race_date venue race_number car_number player_name rank top1 top3 score]
      rows_train_top3 = [
        { "race_id" => "r1", "race_date" => "2026-02-20", "venue" => "toride", "race_number" => "1", "car_number" => "1", "player_name" => "A", "rank" => "1", "top1" => "1", "top3" => "1", "score" => "0.92" },
        { "race_id" => "r1", "race_date" => "2026-02-20", "venue" => "toride", "race_number" => "1", "car_number" => "2", "player_name" => "B", "rank" => "2", "top1" => "0", "top3" => "1", "score" => "0.81" },
        { "race_id" => "r1", "race_date" => "2026-02-20", "venue" => "toride", "race_number" => "1", "car_number" => "3", "player_name" => "C", "rank" => "3", "top1" => "0", "top3" => "1", "score" => "0.71" },
        { "race_id" => "r2", "race_date" => "2026-02-21", "venue" => "toride", "race_number" => "1", "car_number" => "1", "player_name" => "A", "rank" => "2", "top1" => "0", "top3" => "1", "score" => "0.75" },
        { "race_id" => "r2", "race_date" => "2026-02-21", "venue" => "toride", "race_number" => "1", "car_number" => "2", "player_name" => "B", "rank" => "1", "top1" => "1", "top3" => "1", "score" => "0.90" },
        { "race_id" => "r2", "race_date" => "2026-02-21", "venue" => "toride", "race_number" => "1", "car_number" => "3", "player_name" => "C", "rank" => "3", "top1" => "0", "top3" => "1", "score" => "0.70" }
      ]
      rows_train_top1 = rows_train_top3.map do |r|
        s = case r["race_id"]
            when "r1" then { "1" => "0.95", "2" => "0.30", "3" => "0.10" }[r["car_number"]]
            else { "1" => "0.35", "2" => "0.96", "3" => "0.12" }[r["car_number"]]
            end
        r.merge("score" => s)
      end
      rows_valid_top3 = rows_train_top3.map { |r| r.merge("race_id" => r["race_id"] == "r1" ? "v1" : "v2") }
      rows_valid_top1 = rows_train_top1.map { |r| r.merge("race_id" => r["race_id"] == "r1" ? "v1" : "v2") }

      write_csv(train_top3_csv, headers, rows_train_top3)
      write_csv(train_top1_csv, headers, rows_train_top1)
      write_csv(valid_top3_csv, headers, rows_valid_top3)
      write_csv(valid_top1_csv, headers, rows_valid_top1)
      write_csv(train_actual_csv, headers, rows_train_top3)
      write_csv(valid_actual_csv, headers, rows_valid_top3)

      _out1, err1, st1 = run_cmd(
        "ruby", "scripts/learn_exotic_profile.rb",
        "--train-top3-csv", train_top3_csv,
        "--train-top1-csv", train_top1_csv,
        "--train-actual-csv", train_actual_csv,
        "--valid-top3-csv", valid_top3_csv,
        "--valid-top1-csv", valid_top1_csv,
        "--valid-actual-csv", valid_actual_csv,
        "--temp-grid", "0.1,0.2",
        "--exp-grid", "0.8,1.0",
        "--objective-n", "5",
        "--out", profile_path
      )
      expect(st1.success?).to be(true), err1

      profile = JSON.parse(File.read(profile_path, encoding: "UTF-8"))
      expect(profile["params"]).to be_a(Hash)
      expect(profile["params"]["win_temperature"]).to be > 0.0

      _out2, err2, st2 = run_cmd(
        "ruby", "scripts/generate_exotics.rb",
        "--in-csv", valid_top3_csv,
        "--win-csv", valid_top1_csv,
        "--out-dir", out_dir,
        "--exacta-top", "2",
        "--trifecta-top", "3",
        "--profile", profile_path
      )
      expect(st2.success?).to be(true), err2
      exacta = CSV.read(File.join(out_dir, "exacta_pred.csv"), headers: true)
      trifecta = CSV.read(File.join(out_dir, "trifecta_pred.csv"), headers: true)
      expect(exacta.size).to eq(4)
      expect(trifecta.size).to eq(6)
    end
  end

  it "learn_exotic_profile.rb: max-trialsとexacta_second_win_exp_gridが機能する" do
    Dir.mktmpdir("spec-exotic-profile-random-") do |tmp|
      train_top3_csv = File.join(tmp, "train_top3.csv")
      train_top1_csv = File.join(tmp, "train_top1.csv")
      valid_top3_csv = File.join(tmp, "valid_top3.csv")
      valid_top1_csv = File.join(tmp, "valid_top1.csv")
      train_actual_csv = File.join(tmp, "train_actual.csv")
      valid_actual_csv = File.join(tmp, "valid_actual.csv")
      profile_path = File.join(tmp, "exotic_profile.json")
      out_dir = File.join(tmp, "out")

      headers = %w[race_id race_date venue race_number car_number player_name rank top1 top3 score]
      rows = [
        { "race_id" => "r1", "race_date" => "2026-02-20", "venue" => "toride", "race_number" => "1", "car_number" => "1", "player_name" => "A", "rank" => "1", "top1" => "1", "top3" => "1", "score" => "0.90" },
        { "race_id" => "r1", "race_date" => "2026-02-20", "venue" => "toride", "race_number" => "1", "car_number" => "2", "player_name" => "B", "rank" => "2", "top1" => "0", "top3" => "1", "score" => "0.80" },
        { "race_id" => "r1", "race_date" => "2026-02-20", "venue" => "toride", "race_number" => "1", "car_number" => "3", "player_name" => "C", "rank" => "3", "top1" => "0", "top3" => "1", "score" => "0.70" },
        { "race_id" => "r2", "race_date" => "2026-02-21", "venue" => "toride", "race_number" => "1", "car_number" => "1", "player_name" => "A", "rank" => "2", "top1" => "0", "top3" => "1", "score" => "0.78" },
        { "race_id" => "r2", "race_date" => "2026-02-21", "venue" => "toride", "race_number" => "1", "car_number" => "2", "player_name" => "B", "rank" => "1", "top1" => "1", "top3" => "1", "score" => "0.88" },
        { "race_id" => "r2", "race_date" => "2026-02-21", "venue" => "toride", "race_number" => "1", "car_number" => "3", "player_name" => "C", "rank" => "3", "top1" => "0", "top3" => "1", "score" => "0.72" }
      ]
      rows_top1 = rows.map do |r|
        s = case r["race_id"]
            when "r1" then { "1" => "0.95", "2" => "0.28", "3" => "0.10" }[r["car_number"]]
            else { "1" => "0.35", "2" => "0.96", "3" => "0.12" }[r["car_number"]]
            end
        r.merge("score" => s)
      end
      rows_valid = rows.map { |r| r.merge("race_id" => r["race_id"] == "r1" ? "v1" : "v2") }
      rows_valid_top1 = rows_top1.map { |r| r.merge("race_id" => r["race_id"] == "r1" ? "v1" : "v2") }

      write_csv(train_top3_csv, headers, rows)
      write_csv(train_top1_csv, headers, rows_top1)
      write_csv(valid_top3_csv, headers, rows_valid)
      write_csv(valid_top1_csv, headers, rows_valid_top1)
      write_csv(train_actual_csv, headers, rows)
      write_csv(valid_actual_csv, headers, rows_valid)

      _out1, err1, st1 = run_cmd(
        "ruby", "scripts/learn_exotic_profile.rb",
        "--train-top3-csv", train_top3_csv,
        "--train-top1-csv", train_top1_csv,
        "--train-actual-csv", train_actual_csv,
        "--valid-top3-csv", valid_top3_csv,
        "--valid-top1-csv", valid_top1_csv,
        "--valid-actual-csv", valid_actual_csv,
        "--temp-grid", "0.1,0.2",
        "--exp-grid", "0.8,1.0",
        "--exacta-second-win-exp-grid", "0.0,0.5",
        "--max-trials", "3",
        "--random-seed", "7",
        "--out", profile_path
      )
      expect(st1.success?).to be(true), err1

      profile = JSON.parse(File.read(profile_path, encoding: "UTF-8"))
      expect(profile.dig("search_space", "total_combinations")).to eq(64)
      expect(profile.dig("search_space", "searched_combinations")).to eq(3)
      expect(profile.dig("params", "exacta", "second_win_exp")).to be >= 0.0

      _out2, err2, st2 = run_cmd(
        "ruby", "scripts/generate_exotics.rb",
        "--in-csv", valid_top3_csv,
        "--win-csv", valid_top1_csv,
        "--out-dir", out_dir,
        "--exacta-top", "2",
        "--trifecta-top", "3",
        "--exacta-second-win-exp", "0.3"
      )
      expect(st2.success?).to be(true), err2
    end
  end

  it "learn_exotic_profile.rb: configを読み込みつつCLI上書きが優先される" do
    Dir.mktmpdir("spec-exotic-profile-config-") do |tmp|
      train_top3_csv = File.join(tmp, "train_top3.csv")
      train_top1_csv = File.join(tmp, "train_top1.csv")
      valid_top3_csv = File.join(tmp, "valid_top3.csv")
      valid_top1_csv = File.join(tmp, "valid_top1.csv")
      train_actual_csv = File.join(tmp, "train_actual.csv")
      valid_actual_csv = File.join(tmp, "valid_actual.csv")
      profile_path = File.join(tmp, "exotic_profile.json")
      config_path = File.join(tmp, "profile_config.yml")

      headers = %w[race_id race_date venue race_number car_number player_name rank top1 top3 score]
      rows = [
        { "race_id" => "r1", "race_date" => "2026-02-20", "venue" => "toride", "race_number" => "1", "car_number" => "1", "player_name" => "A", "rank" => "1", "top1" => "1", "top3" => "1", "score" => "0.90" },
        { "race_id" => "r1", "race_date" => "2026-02-20", "venue" => "toride", "race_number" => "1", "car_number" => "2", "player_name" => "B", "rank" => "2", "top1" => "0", "top3" => "1", "score" => "0.80" },
        { "race_id" => "r1", "race_date" => "2026-02-20", "venue" => "toride", "race_number" => "1", "car_number" => "3", "player_name" => "C", "rank" => "3", "top1" => "0", "top3" => "1", "score" => "0.70" }
      ]
      rows_top1 = [
        rows[0].merge("score" => "0.95"),
        rows[1].merge("score" => "0.28"),
        rows[2].merge("score" => "0.10")
      ]
      write_csv(train_top3_csv, headers, rows)
      write_csv(train_top1_csv, headers, rows_top1)
      write_csv(valid_top3_csv, headers, rows)
      write_csv(valid_top1_csv, headers, rows_top1)
      write_csv(train_actual_csv, headers, rows)
      write_csv(valid_actual_csv, headers, rows)

      File.write(
        config_path,
        <<~YAML
          objective_n: 1
          exacta_weight: 1.0
          trifecta_weight: 0.0
          temp_grid: [0.1, 0.2]
          exp_grid: [0.8, 1.0]
          exacta_second_win_exp_grid: [0.0]
          max_trials: 1
          random_seed: 7
        YAML
      )

      _out, err, st = run_cmd(
        "ruby", "scripts/learn_exotic_profile.rb",
        "--config", config_path,
        "--train-top3-csv", train_top3_csv,
        "--train-top1-csv", train_top1_csv,
        "--train-actual-csv", train_actual_csv,
        "--valid-top3-csv", valid_top3_csv,
        "--valid-top1-csv", valid_top1_csv,
        "--valid-actual-csv", valid_actual_csv,
        "--objective-n", "5",
        "--out", profile_path
      )
      expect(st.success?).to be(true), err

      profile = JSON.parse(File.read(profile_path, encoding: "UTF-8"))
      expect(profile.dig("config", "path")).to eq(config_path)
      expect(profile["optimized_for"]).to eq("hit@5")
      expect(profile.dig("search_space", "searched_combinations")).to eq(1)
    end
  end

  it "learn_exotic_profile.rb: 不正なconfig値は明示エラーになる" do
    Dir.mktmpdir("spec-exotic-profile-config-invalid-") do |tmp|
      train_top3_csv = File.join(tmp, "train_top3.csv")
      train_top1_csv = File.join(tmp, "train_top1.csv")
      valid_top3_csv = File.join(tmp, "valid_top3.csv")
      valid_top1_csv = File.join(tmp, "valid_top1.csv")
      train_actual_csv = File.join(tmp, "train_actual.csv")
      valid_actual_csv = File.join(tmp, "valid_actual.csv")
      profile_path = File.join(tmp, "exotic_profile.json")
      config_path = File.join(tmp, "profile_config.yml")

      headers = %w[race_id race_date venue race_number car_number player_name rank top1 top3 score]
      rows = [
        { "race_id" => "r1", "race_date" => "2026-02-20", "venue" => "toride", "race_number" => "1", "car_number" => "1", "player_name" => "A", "rank" => "1", "top1" => "1", "top3" => "1", "score" => "0.90" },
        { "race_id" => "r1", "race_date" => "2026-02-20", "venue" => "toride", "race_number" => "1", "car_number" => "2", "player_name" => "B", "rank" => "2", "top1" => "0", "top3" => "1", "score" => "0.80" },
        { "race_id" => "r1", "race_date" => "2026-02-20", "venue" => "toride", "race_number" => "1", "car_number" => "3", "player_name" => "C", "rank" => "3", "top1" => "0", "top3" => "1", "score" => "0.70" }
      ]
      rows_top1 = [
        rows[0].merge("score" => "0.95"),
        rows[1].merge("score" => "0.28"),
        rows[2].merge("score" => "0.10")
      ]
      write_csv(train_top3_csv, headers, rows)
      write_csv(train_top1_csv, headers, rows_top1)
      write_csv(valid_top3_csv, headers, rows)
      write_csv(valid_top1_csv, headers, rows_top1)
      write_csv(train_actual_csv, headers, rows)
      write_csv(valid_actual_csv, headers, rows)

      File.write(
        config_path,
        <<~YAML
          objective_n: 5
          exacta_weight: 0.0
          trifecta_weight: 0.0
          temp_grid: [0.1]
          exp_grid: [0.8]
          exacta_second_win_exp_grid: [0.0]
          max_trials: 1
          random_seed: 7
        YAML
      )

      _out, err, st = run_cmd(
        "ruby", "scripts/learn_exotic_profile.rb",
        "--config", config_path,
        "--train-top3-csv", train_top3_csv,
        "--train-top1-csv", train_top1_csv,
        "--train-actual-csv", train_actual_csv,
        "--valid-top3-csv", valid_top3_csv,
        "--valid-top1-csv", valid_top1_csv,
        "--valid-actual-csv", valid_actual_csv,
        "--out", profile_path
      )
      expect(st.success?).to be(false)
      expect(err).to include("exacta_weight and trifecta_weight cannot both be 0")
    end
  end

  it "evaluate_exotics.rb: nsが空ならエラーになる" do
    Dir.mktmpdir("spec-exotic-ns-empty-") do |tmp|
      actual_csv = File.join(tmp, "actual.csv")
      pred_exacta = File.join(tmp, "exacta.csv")
      pred_trifecta = File.join(tmp, "trifecta.csv")
      headers = %w[race_id race_date venue race_number car_number player_name rank top1 top3 score]
      write_csv(actual_csv, headers, [])
      write_csv(pred_exacta, %w[race_id first_car_number second_car_number score], [])
      write_csv(pred_trifecta, %w[race_id first_car_number second_car_number third_car_number score], [])

      _out, err, st = run_cmd(
        "ruby", "scripts/evaluate_exotics.rb",
        "--actual-csv", actual_csv,
        "--exacta-csv", pred_exacta,
        "--trifecta-csv", pred_trifecta,
        "--out", File.join(tmp, "out.json"),
        "--ns", ",,,"
      )
      expect(st.success?).to be(false)
      expect(err).to include("ns is empty")
    end
  end

  it "generate_exotics.rb: 入力CSVが空ならエラーになる" do
    Dir.mktmpdir("spec-generate-exotic-empty-") do |tmp|
      in_csv = File.join(tmp, "valid_pred.csv")
      win_csv = File.join(tmp, "valid_pred_top1.csv")
      write_csv(in_csv, %w[race_id car_number score], [])
      write_csv(win_csv, %w[race_id car_number score], [])

      _out, err, st = run_cmd(
        "ruby", "scripts/generate_exotics.rb",
        "--in-csv", in_csv,
        "--win-csv", win_csv,
        "--out-dir", tmp
      )
      expect(st.success?).to be(false)
      expect(err).to include("input is empty")
    end
  end
end
