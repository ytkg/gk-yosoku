# frozen_string_literal: true

require "csv"
require "digest"
require "fileutils"
require "json"
require "open3"
require "tmpdir"

RSpec.describe "scripts CLI" do
  REPO_ROOT = File.expand_path("..", __dir__)

  def run_cmd(*args, env: {}, chdir: REPO_ROOT)
    Open3.capture3(env, *args, chdir: chdir)
  end

  def write_csv(path, headers, rows)
    FileUtils.mkdir_p(File.dirname(path))
    CSV.open(path, "w", write_headers: true, headers: headers) do |csv|
      rows.each { |r| csv << headers.map { |h| r[h] } }
    end
  end

  def create_fake_lightgbm(bin_dir)
    FileUtils.mkdir_p(bin_dir)
    path = File.join(bin_dir, "lightgbm")
    File.write(path, <<~'RUBY')
      #!/usr/bin/env ruby
      config_arg = ARGV.find { |a| a.start_with?("config=") }
      abort("missing config") if config_arg.nil?
      conf_path = config_arg.split("=", 2)[1]

      conf = {}
      File.readlines(conf_path, chomp: true).each do |line|
        next if line.strip.empty? || line.start_with?("#")
        k, v = line.split("=", 2)
        conf[k] = v
      end

      case conf["task"]
      when "train"
        File.write(conf.fetch("output_model"), "dummy model\n")
        puts "train ok"
      when "predict"
        rows = File.readlines(conf.fetch("data"), chomp: true).reject { |l| l.strip.empty? }
        File.open(conf.fetch("output_result"), "w") do |f|
          rows.each_with_index { |_, i| f.puts(format("%.6f", 0.9 - (i * 0.01))) }
        end
        puts "predict ok"
      else
        abort("unknown task: #{conf['task']}")
      end
    RUBY
    FileUtils.chmod("u+x", path)
    path
  end

  def feature_headers
    %w[
      race_id race_date venue race_number racedetail_id player_name car_number rank top1 top3
      hist_races hist_win_rate hist_top3_rate hist_avg_rank hist_last_rank
      hist_recent5_weighted_avg_rank hist_recent5_win_rate hist_recent5_top3_rate hist_days_since_last
      race_rel_hist_win_rate_rank race_rel_hist_top3_rate_rank mark_symbol leg_style
      odds_2shatan_min_first race_rel_odds_2shatan_rank race_field_size
    ]
  end

  def sample_feature_rows(date:, race_id:, racedetail_id: "2320260225010001")
    [
      { "race_id" => race_id, "race_date" => date, "venue" => "toride", "race_number" => "1", "racedetail_id" => racedetail_id,
        "player_name" => "A", "car_number" => "1", "rank" => "1", "top1" => "1", "top3" => "1",
        "hist_races" => "10", "hist_win_rate" => "0.200000", "hist_top3_rate" => "0.500000", "hist_avg_rank" => "3.200000", "hist_last_rank" => "2",
        "hist_recent5_weighted_avg_rank" => "2.800000", "hist_recent5_win_rate" => "0.200000", "hist_recent5_top3_rate" => "0.600000", "hist_days_since_last" => "3",
        "race_rel_hist_win_rate_rank" => "1", "race_rel_hist_top3_rate_rank" => "1", "mark_symbol" => "◎", "leg_style" => "逃",
        "odds_2shatan_min_first" => "1.200000", "race_rel_odds_2shatan_rank" => "1", "race_field_size" => "3" },
      { "race_id" => race_id, "race_date" => date, "venue" => "toride", "race_number" => "1", "racedetail_id" => racedetail_id,
        "player_name" => "B", "car_number" => "2", "rank" => "2", "top1" => "0", "top3" => "1",
        "hist_races" => "8", "hist_win_rate" => "0.125000", "hist_top3_rate" => "0.375000", "hist_avg_rank" => "3.700000", "hist_last_rank" => "3",
        "hist_recent5_weighted_avg_rank" => "3.100000", "hist_recent5_win_rate" => "0.000000", "hist_recent5_top3_rate" => "0.400000", "hist_days_since_last" => "5",
        "race_rel_hist_win_rate_rank" => "2", "race_rel_hist_top3_rate_rank" => "2", "mark_symbol" => "○", "leg_style" => "両",
        "odds_2shatan_min_first" => "2.300000", "race_rel_odds_2shatan_rank" => "2", "race_field_size" => "3" },
      { "race_id" => race_id, "race_date" => date, "venue" => "toride", "race_number" => "1", "racedetail_id" => racedetail_id,
        "player_name" => "C", "car_number" => "3", "rank" => "3", "top1" => "0", "top3" => "1",
        "hist_races" => "6", "hist_win_rate" => "0.000000", "hist_top3_rate" => "0.166666", "hist_avg_rank" => "4.100000", "hist_last_rank" => "5",
        "hist_recent5_weighted_avg_rank" => "4.200000", "hist_recent5_win_rate" => "0.000000", "hist_recent5_top3_rate" => "0.200000", "hist_days_since_last" => "9",
        "race_rel_hist_win_rate_rank" => "3", "race_rel_hist_top3_rate_rank" => "3", "mark_symbol" => "▲", "leg_style" => "追",
        "odds_2shatan_min_first" => "5.100000", "race_rel_odds_2shatan_rank" => "3", "race_field_size" => "3" }
    ]
  end

  it "collect_data.rb: cache HTMLからCSVを作る" do
    Dir.mktmpdir("spec-collect-") do |tmp|
      raw_dir = File.join(tmp, "raw")
      raw_html_dir = File.join(tmp, "raw_html")
      date = "2026-02-26"
      ymd = "20260226"
      FileUtils.mkdir_p(File.join(raw_html_dir, "results", ymd))

      show_url = "https://keirin.kdreams.jp/toride/racedetail/2320260226010001/?pageType=showResult"
      kaisai_html = <<~HTML
        <div class="kaisai-list" id="k1">
          <div class="kaisai-program_table">
            <table>
              <tr><td class="program_bg_7">girls</td></tr>
              <tr><td><a href="#{show_url}">result</a></td></tr>
            </table>
          </div>
        </div>
      HTML
      File.write(File.join(raw_html_dir, "kaisai_#{ymd}.html"), kaisai_html)

      result_html = <<~HTML
        <table class="result_table">
          <tr><td>x</td><td>1</td><td>1</td><td>選手A</td></tr>
          <tr><td>x</td><td>2</td><td>2</td><td>選手B</td></tr>
          <tr><td>x</td><td>落</td><td>3</td><td>選手C</td></tr>
        </table>
      HTML
      hash = Digest::SHA1.hexdigest(show_url)
      File.write(File.join(raw_html_dir, "results", ymd, "result_#{hash}.html"), result_html)

      _out, err, status = run_cmd(
        "ruby", "scripts/collect_data.rb",
        "--from-date", date,
        "--to-date", date,
        "--raw-dir", raw_dir,
        "--raw-html-dir", raw_html_dir,
        "--cache",
        "--sleep", "0"
      )
      expect(status.success?).to be(true), err

      races = CSV.read(File.join(raw_dir, "girls_races_#{ymd}.csv"), headers: true)
      results = CSV.read(File.join(raw_dir, "girls_results_#{ymd}.csv"), headers: true)
      expect(races.size).to eq(1)
      expect(results.size).to eq(3)
      expect(results.map { |r| r["result_status"] }).to include("fall")
    end
  end

  it "build_features.rb: results CSVからfeaturesを作る" do
    Dir.mktmpdir("spec-features-") do |tmp|
      in_dir = File.join(tmp, "raw")
      out_dir = File.join(tmp, "features")
      raw_html_dir = File.join(tmp, "raw_html")
      ymd = "20260226"
      write_csv(
        File.join(in_dir, "girls_results_#{ymd}.csv"),
        %w[race_date venue race_number racedetail_id show_result_url rank result_status frame_number car_number player_name age class raw_cells],
        [
          { "race_date" => "2026-02-26", "venue" => "toride", "race_number" => "1", "racedetail_id" => "2320260226010001", "show_result_url" => "u", "rank" => "1", "result_status" => "normal", "frame_number" => "", "car_number" => "1", "player_name" => "A", "age" => "", "class" => "", "raw_cells" => "◎ | 1 | 1 | A" },
          { "race_date" => "2026-02-26", "venue" => "toride", "race_number" => "1", "racedetail_id" => "2320260226010001", "show_result_url" => "u", "rank" => "2", "result_status" => "normal", "frame_number" => "", "car_number" => "2", "player_name" => "B", "age" => "", "class" => "", "raw_cells" => "○ | 2 | 2 | B" },
          { "race_date" => "2026-02-26", "venue" => "toride", "race_number" => "1", "racedetail_id" => "2320260226010001", "show_result_url" => "u", "rank" => "3", "result_status" => "normal", "frame_number" => "", "car_number" => "3", "player_name" => "C", "age" => "", "class" => "", "raw_cells" => "▲ | 3 | 3 | C" }
        ]
      )

      _out, err, status = run_cmd(
        "ruby", "scripts/build_features.rb",
        "--from-date", "2026-02-26",
        "--to-date", "2026-02-26",
        "--in-dir", in_dir,
        "--out-dir", out_dir,
        "--raw-html-dir", raw_html_dir
      )
      expect(status.success?).to be(true), err

      rows = CSV.read(File.join(out_dir, "features_20260226.csv"), headers: true)
      expect(rows.size).to eq(3)
      expect(rows.first["top1"]).to eq("1")
      expect(rows.map { |r| r["top3"] }.uniq).to eq(["1"])
    end
  end

  it "split_features.rb: train/validに分割する" do
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

  it "train/eval/tune: fake lightgbmで実行できる" do
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

  it "generate_exotics.rb/evaluate_exotics.rb: 候補生成とhit@N評価" do
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

  it "predict_race.rb: URL引数で予測を出せる（cache + fake lightgbm）" do
    Dir.mktmpdir("spec-predict-") do |tmp|
      bin_dir = File.join(tmp, "bin")
      create_fake_lightgbm(bin_dir)
      env = { "PATH" => "#{bin_dir}:#{ENV.fetch('PATH', '')}" }

      url = "https://keirin.kdreams.jp/toride/racedetail/2320260225030004/"
      cache_dir = File.join(tmp, "cache")
      raw_dir = File.join(tmp, "raw")
      model_dir = File.join(tmp, "models")
      FileUtils.mkdir_p(cache_dir)
      FileUtils.mkdir_p(raw_dir)
      FileUtils.mkdir_p(model_dir)

      html = <<~HTML
        <table class="racecard_table">
          <tr class="n1">
            <td class="num"><span>1</span></td>
            <td class="rider bdr_r">A</td>
            <td class="bdr_r">逃</td>
            <span class="icon_t1">◎</span>
          </tr>
          <tr class="n2">
            <td class="num"><span>2</span></td>
            <td class="rider bdr_r">B</td>
            <td class="bdr_r">両</td>
            <span class="icon_t2">○</span>
          </tr>
          <tr class="n3">
            <td class="num"><span>3</span></td>
            <td class="rider bdr_r">C</td>
            <td class="bdr_r">追</td>
            <span class="icon_t3">▲</span>
          </tr>
          脚<br>質
        </table>
        <div class="odds_contents" id="JS_ODDSCONTENTS_2shatan">
          <table class="odds_table">
            <tr><th class="n1">1</th><td>1.2</td><td>2.3</td></tr>
            <tr><th class="n2">2</th><td>2.1</td><td>3.4</td></tr>
            <tr><th class="n3">3</th><td>3.1</td><td>4.4</td></tr>
          </table>
          <!-- 2車単 End -->
        </div>
      HTML
      cache_path = File.join(cache_dir, "race_#{Digest::SHA1.hexdigest(url)}.html")
      File.write(cache_path, html)

      write_csv(
        File.join(raw_dir, "girls_results_20260226.csv"),
        %w[race_date venue race_number racedetail_id show_result_url rank result_status frame_number car_number player_name age class raw_cells],
        [
          { "race_date" => "2026-02-26", "venue" => "toride", "race_number" => "1", "racedetail_id" => "x", "show_result_url" => "u", "rank" => "1", "result_status" => "normal", "frame_number" => "", "car_number" => "1", "player_name" => "A", "age" => "", "class" => "", "raw_cells" => "" },
          { "race_date" => "2026-02-26", "venue" => "toride", "race_number" => "1", "racedetail_id" => "x", "show_result_url" => "u", "rank" => "2", "result_status" => "normal", "frame_number" => "", "car_number" => "2", "player_name" => "B", "age" => "", "class" => "", "raw_cells" => "" },
          { "race_date" => "2026-02-26", "venue" => "toride", "race_number" => "1", "racedetail_id" => "x", "show_result_url" => "u", "rank" => "3", "result_status" => "normal", "frame_number" => "", "car_number" => "3", "player_name" => "C", "age" => "", "class" => "", "raw_cells" => "" }
        ]
      )

      encoders = {
        "venue" => { "toride" => 0 },
        "player_name" => { "A" => 0, "B" => 1, "C" => 2 },
        "mark_symbol" => { "◎" => 0, "○" => 1, "▲" => 2 },
        "leg_style" => { "逃" => 0, "両" => 1, "追" => 2 }
      }
      File.write(File.join(model_dir, "model_top3.txt"), "dummy")
      File.write(File.join(model_dir, "model_top1.txt"), "dummy")
      File.write(File.join(model_dir, "enc_top3.json"), JSON.pretty_generate(encoders))
      File.write(File.join(model_dir, "enc_top1.json"), JSON.pretty_generate(encoders))

      out, err, st = run_cmd(
        "ruby", "scripts/predict_race.rb",
        "--url", url,
        "--model-top3", File.join(model_dir, "model_top3.txt"),
        "--encoders-top3", File.join(model_dir, "enc_top3.json"),
        "--model-top1", File.join(model_dir, "model_top1.txt"),
        "--encoders-top1", File.join(model_dir, "enc_top1.json"),
        "--raw-dir", raw_dir,
        "--cache-dir", cache_dir,
        "--exacta-top", "3",
        "--trifecta-top", "3",
        "--cache",
        env: env
      )
      expect(st.success?).to be(true), err
      expect(out).to include("# Race: toride")
      expect(out).to include("## Exacta Top 3")
      expect(out).to include("## Trifecta Top 3")
    end
  end
end
