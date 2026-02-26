#!/usr/bin/env ruby
# frozen_string_literal: true

require "csv"
require "json"
require "open3"
require "optparse"

class LightGBMEvaluator
  CATEGORICAL_FEATURES = %w[venue player_name mark_symbol leg_style].freeze
  NUMERIC_FEATURES = %w[
    race_number
    car_number
    hist_races
    hist_win_rate
    hist_top3_rate
    hist_avg_rank
    hist_last_rank
    hist_recent5_weighted_avg_rank
    hist_recent5_win_rate
    hist_recent5_top3_rate
    hist_days_since_last
    race_rel_hist_win_rate_rank
    race_rel_hist_top3_rate_rank
    odds_2shatan_min_first
    race_rel_odds_2shatan_rank
    race_field_size
  ].freeze
  FEATURE_COLUMNS = (CATEGORICAL_FEATURES + NUMERIC_FEATURES).freeze

  def initialize(model_path:, valid_csv:, encoder_path:, out_dir:, target_col:)
    @model_path = model_path
    @valid_csv = valid_csv
    @encoder_path = encoder_path
    @out_dir = out_dir
    @target_col = target_col
  end

  def run
    check_lightgbm!

    rows = CSV.read(@valid_csv, headers: true, encoding: "UTF-8").map(&:to_h)
    raise "empty valid rows" if rows.empty?
    raise "missing target column: #{@target_col}" unless rows.first.key?(@target_col)
    encoders = JSON.parse(File.read(@encoder_path, encoding: "UTF-8"))

    valid_tsv = File.join(@out_dir, "valid_eval.tsv")
    pred_path = File.join(@out_dir, "valid_pred.txt")
    pred_csv = File.join(@out_dir, "valid_pred.csv")
    summary_path = File.join(@out_dir, "eval_summary.json")

    write_eval_tsv(valid_tsv, rows, encoders)
    run_predict(valid_tsv, pred_path)
    preds = read_scores(pred_path)
    raise "prediction size mismatch: rows=#{rows.size} preds=#{preds.size}" if rows.size != preds.size

    rows_with_score = rows.each_with_index.map { |r, i| r.merge("score" => preds[i]) }
    write_pred_csv(pred_csv, rows_with_score)

    summary = evaluate(rows_with_score)
    File.write(summary_path, JSON.pretty_generate(summary))

    warn "auc=#{format('%.6f', summary['auc'])}"
    warn "target=#{@target_col}"
    warn "top3_exact_match_rate=#{format('%.6f', summary['top3_exact_match_rate'])}" if summary.key?("top3_exact_match_rate")
    warn "top3_recall_at3=#{format('%.6f', summary['top3_recall_at3'])}" if summary.key?("top3_recall_at3")
    warn "winner_hit_rate=#{format('%.6f', summary['winner_hit_rate'])}"
    warn "summary=#{summary_path}"
  end

  private

  def check_lightgbm!
    return if system("command -v lightgbm >/dev/null 2>&1")

    raise "lightgbm command not found"
  end

  def write_eval_tsv(path, rows, encoders)
    File.open(path, "w") do |f|
      rows.each do |r|
        y = r[@target_col].to_i
        xs = FEATURE_COLUMNS.map do |name|
          if CATEGORICAL_FEATURES.include?(name)
            (encoders.fetch(name, {})[r[name].to_s] || -1).to_s
          else
            to_float(r[name])
          end
        end
        f.puts(([y] + xs).join("\t"))
      end
    end
  end

  def to_float(v)
    return "0.0" if v.nil? || v.to_s.strip.empty?

    v.to_f.to_s
  end

  def run_predict(valid_tsv, pred_path)
    conf_path = File.join(@out_dir, "lightgbm_predict.conf")
    File.write(conf_path, <<~CONF)
      task=predict
      data=#{valid_tsv}
      input_model=#{@model_path}
      output_result=#{pred_path}
      header=false
    CONF

    out, err, status = Open3.capture3("lightgbm", "config=#{conf_path}")
    raise "lightgbm predict failed: #{err}\n#{out}" unless status.success?
  end

  def read_scores(path)
    File.readlines(path, chomp: true).map(&:to_f)
  end

  def write_pred_csv(path, rows)
    headers = %w[race_id race_date venue race_number car_number player_name rank top1 top3 score]
    CSV.open(path, "w", write_headers: true, headers: headers) do |csv|
      rows.each { |r| csv << headers.map { |h| r[h] } }
    end
  end

  def evaluate(rows)
    y_true = rows.map { |r| r[@target_col].to_i }
    y_score = rows.map { |r| r["score"].to_f }

    base = {
      "rows" => rows.size,
      "auc" => auc(y_true, y_score),
      "races" => race_count(rows),
      "winner_hit_rate" => winner_hit_rate(rows)
    }
    if @target_col == "top3"
      base["top3_exact_match_rate"] = top3_exact_match_rate(rows)
      base["top3_recall_at3"] = top3_recall_at3(rows)
    end
    base
  end

  def race_count(rows)
    rows.map { |r| r["race_id"] }.uniq.size
  end

  def top3_exact_match_rate(rows)
    grouped = rows.group_by { |r| r["race_id"] }
    ok = grouped.count do |_race_id, rs|
      actual = rs.select { |x| x["top3"].to_i == 1 }.map { |x| x["car_number"] }.sort
      pred = rs.sort_by { |x| -x["score"].to_f }.first(3).map { |x| x["car_number"] }.sort
      actual == pred
    end
    ok.to_f / grouped.size
  end

  def top3_recall_at3(rows)
    grouped = rows.group_by { |r| r["race_id"] }
    sum = grouped.sum do |_race_id, rs|
      actual = rs.select { |x| x["top3"].to_i == 1 }.map { |x| x["car_number"] }
      pred = rs.sort_by { |x| -x["score"].to_f }.first(3).map { |x| x["car_number"] }
      (actual & pred).size.to_f / 3.0
    end
    sum / grouped.size
  end

  def winner_hit_rate(rows)
    grouped = rows.group_by { |r| r["race_id"] }
    hit = grouped.count do |_race_id, rs|
      winner = rs.find { |x| x["rank"].to_i == 1 }
      next false if winner.nil?

      pred1 = rs.max_by { |x| x["score"].to_f }
      pred1["car_number"] == winner["car_number"]
    end
    hit.to_f / grouped.size
  end

  def auc(y_true, y_score)
    pairs = y_true.zip(y_score).sort_by { |(_, s)| s }
    n_pos = y_true.count(1)
    n_neg = y_true.count(0)
    return 0.0 if n_pos.zero? || n_neg.zero?

    ranks = Array.new(pairs.size, 0.0)
    i = 0
    while i < pairs.size
      j = i
      j += 1 while j < pairs.size && pairs[j][1] == pairs[i][1]
      avg_rank = (i + 1 + j) / 2.0
      (i...j).each { |k| ranks[k] = avg_rank }
      i = j
    end

    sum_pos_ranks = 0.0
    pairs.each_with_index do |(y, _s), idx|
      sum_pos_ranks += ranks[idx] if y == 1
    end

    (sum_pos_ranks - (n_pos * (n_pos + 1) / 2.0)) / (n_pos * n_neg)
  end
end

options = {
  model_path: File.join("data", "ml", "model.txt"),
  valid_csv: File.join("data", "ml", "valid.csv"),
  encoder_path: File.join("data", "ml", "encoders.json"),
  out_dir: File.join("data", "ml"),
  target_col: "top3"
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: ruby scripts/evaluate_lightgbm.rb [options]"
  opts.on("--model PATH", "LightGBM model path") { |v| options[:model_path] = v }
  opts.on("--valid-csv PATH", "validation CSV path") { |v| options[:valid_csv] = v }
  opts.on("--encoders PATH", "encoders.json path") { |v| options[:encoder_path] = v }
  opts.on("--out-dir DIR", "output dir") { |v| options[:out_dir] = v }
  opts.on("--target-col NAME", "target column name (top3 or top1)") { |v| options[:target_col] = v }
end
parser.parse!

LightGBMEvaluator.new(
  model_path: options[:model_path],
  valid_csv: options[:valid_csv],
  encoder_path: options[:encoder_path],
  out_dir: options[:out_dir],
  target_col: options[:target_col]
).run
