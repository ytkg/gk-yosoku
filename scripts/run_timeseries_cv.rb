#!/usr/bin/env ruby
# frozen_string_literal: true

require "csv"
require "date"
require "fileutils"
require "json"
require "open3"
require "optparse"

class TimeSeriesCVRunner
  def initialize(from_date:, to_date:, train_days:, valid_days:, step_days:, in_dir:, out_dir:, target_col:, drop_features:, weight_mode:, decay_half_life_days:, min_sample_weight:)
    @from_date = Date.iso8601(from_date)
    @to_date = Date.iso8601(to_date)
    @train_days = train_days.to_i
    @valid_days = valid_days.to_i
    @step_days = step_days.to_i
    @in_dir = in_dir
    @out_dir = out_dir
    @target_col = target_col
    @drop_features = drop_features
    @weight_mode = weight_mode
    @decay_half_life_days = decay_half_life_days
    @min_sample_weight = min_sample_weight

    validate_options!
    FileUtils.mkdir_p(@out_dir)
  end

  def run
    folds = build_folds
    raise "no folds generated. adjust train_days/valid_days/step_days/date range" if folds.empty?

    results = []
    folds.each_with_index do |fold, idx|
      fold_id = format("fold_%02d", idx + 1)
      fold_dir = File.join(@out_dir, fold_id)
      split_dir = File.join(fold_dir, "split")
      model_dir = File.join(fold_dir, "model")
      eval_dir = File.join(fold_dir, "eval")
      FileUtils.mkdir_p(split_dir)
      FileUtils.mkdir_p(model_dir)
      FileUtils.mkdir_p(eval_dir)

      run_split!(split_dir, fold)
      run_train!(split_dir, model_dir)
      summary = run_eval!(split_dir, model_dir, eval_dir)

      row = {
        "fold" => fold_id,
        "train_from" => fold[:train_from].iso8601,
        "train_to" => fold[:train_to].iso8601,
        "valid_from" => fold[:valid_from].iso8601,
        "valid_to" => fold[:valid_to].iso8601,
        "target_col" => @target_col,
        "rows" => summary["rows"],
        "races" => summary["races"],
        "auc" => summary["auc"],
        "winner_hit_rate" => summary["winner_hit_rate"],
        "top3_exact_match_rate" => summary["top3_exact_match_rate"],
        "top3_recall_at3" => summary["top3_recall_at3"]
      }
      results << row
      warn(
        "fold=#{fold_id} train=#{row['train_from']}..#{row['train_to']} " \
        "valid=#{row['valid_from']}..#{row['valid_to']} " \
        "auc=#{format('%.6f', row['auc'])} winner_hit_rate=#{format('%.6f', row['winner_hit_rate'])}"
      )
    end

    write_results(results)
  end

  private

  def validate_options!
    raise ArgumentError, "from_date must be <= to_date" if @from_date > @to_date
    raise ArgumentError, "train_days must be > 0" if @train_days <= 0
    raise ArgumentError, "valid_days must be > 0" if @valid_days <= 0
    raise ArgumentError, "step_days must be > 0" if @step_days <= 0
    raise ArgumentError, "target_col must be top3 or top1" unless %w[top3 top1].include?(@target_col)
  end

  def build_folds
    folds = []
    valid_start = @from_date + @train_days
    while valid_start <= @to_date
      train_from = valid_start - @train_days
      break if train_from < @from_date

      train_to = valid_start - 1
      valid_to = [valid_start + @valid_days - 1, @to_date].min
      folds << {
        train_from: train_from,
        train_to: train_to,
        valid_from: valid_start,
        valid_to: valid_to
      }
      valid_start += @step_days
    end
    folds
  end

  def run_split!(split_dir, fold)
    cmd = [
      "ruby", "scripts/split_features.rb",
      "--from-date", fold[:train_from].iso8601,
      "--to-date", fold[:valid_to].iso8601,
      "--train-to", fold[:train_to].iso8601,
      "--in-dir", @in_dir,
      "--out-dir", split_dir
    ]
    run_cmd!(cmd)
  end

  def run_train!(split_dir, model_dir)
    cmd = [
      "ruby", "scripts/train_lightgbm.rb",
      "--train-csv", File.join(split_dir, "train.csv"),
      "--valid-csv", File.join(split_dir, "valid.csv"),
      "--out-dir", model_dir,
      "--target-col", @target_col,
      "--weight-mode", @weight_mode.to_s,
      "--decay-half-life-days", @decay_half_life_days.to_s,
      "--min-sample-weight", @min_sample_weight.to_s
    ]
    cmd += ["--drop-features", @drop_features.join(",")] unless @drop_features.empty?
    run_cmd!(cmd)
  end

  def run_eval!(split_dir, model_dir, eval_dir)
    cmd = [
      "ruby", "scripts/evaluate_lightgbm.rb",
      "--model", File.join(model_dir, "model.txt"),
      "--encoders", File.join(model_dir, "encoders.json"),
      "--valid-csv", File.join(split_dir, "valid.csv"),
      "--out-dir", eval_dir,
      "--target-col", @target_col
    ]
    run_cmd!(cmd)
    JSON.parse(File.read(File.join(eval_dir, "eval_summary.json"), encoding: "UTF-8"))
  end

  def write_results(rows)
    headers = %w[
      fold train_from train_to valid_from valid_to target_col
      rows races auc winner_hit_rate top3_exact_match_rate top3_recall_at3
    ]
    path = File.join(@out_dir, "cv_results.csv")
    CSV.open(path, "w", write_headers: true, headers: headers) do |csv|
      rows.each { |r| csv << headers.map { |h| r[h] } }
    end

    summary = {
      "folds" => rows.size,
      "target_col" => @target_col,
      "metrics" => {
        "auc" => metric_stats(rows, "auc"),
        "winner_hit_rate" => metric_stats(rows, "winner_hit_rate"),
        "top3_exact_match_rate" => metric_stats(rows, "top3_exact_match_rate"),
        "top3_recall_at3" => metric_stats(rows, "top3_recall_at3")
      }
    }
    json_path = File.join(@out_dir, "cv_summary.json")
    File.write(json_path, JSON.pretty_generate(summary))
    warn "cv_results=#{path}"
    warn "cv_summary=#{json_path}"
  end

  def metric_stats(rows, key)
    values = rows.map { |r| r[key] }.compact.map(&:to_f)
    return nil if values.empty?

    mean = values.sum / values.size.to_f
    var = values.sum { |v| (v - mean)**2 } / values.size.to_f
    { "mean" => mean, "stddev" => Math.sqrt(var), "min" => values.min, "max" => values.max }
  end

  def run_cmd!(cmd)
    out, err, status = Open3.capture3(*cmd)
    return if status.success?

    raise "command failed: #{cmd.join(' ')}\n#{err}\n#{out}"
  end
end

options = {
  from_date: nil,
  to_date: nil,
  train_days: 180,
  valid_days: 28,
  step_days: 28,
  in_dir: File.join("data", "features"),
  out_dir: File.join("data", "ml_cv"),
  target_col: "top3",
  drop_features: [],
  weight_mode: "none",
  decay_half_life_days: 120.0,
  min_sample_weight: 0.2
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: ruby scripts/run_timeseries_cv.rb --from-date YYYY-MM-DD --to-date YYYY-MM-DD [options]"
  opts.on("--from-date DATE", "最小日付 (YYYY-MM-DD)") { |v| options[:from_date] = v }
  opts.on("--to-date DATE", "最大日付 (YYYY-MM-DD)") { |v| options[:to_date] = v }
  opts.on("--train-days N", Integer, "学習窓の日数 (default: 180)") { |v| options[:train_days] = v }
  opts.on("--valid-days N", Integer, "検証窓の日数 (default: 28)") { |v| options[:valid_days] = v }
  opts.on("--step-days N", Integer, "fold間のステップ日数 (default: 28)") { |v| options[:step_days] = v }
  opts.on("--in-dir DIR", "features CSV入力先 (default: data/features)") { |v| options[:in_dir] = v }
  opts.on("--out-dir DIR", "出力先 (default: data/ml_cv)") { |v| options[:out_dir] = v }
  opts.on("--target-col NAME", "top3 or top1 (default: top3)") { |v| options[:target_col] = v }
  opts.on("--drop-features LIST", "除外特徴量のCSVリスト") { |v| options[:drop_features] = v.split(",").map(&:strip).reject(&:empty?) }
  opts.on("--weight-mode MODE", "sample weight mode: none or time_decay (default: none)") { |v| options[:weight_mode] = v }
  opts.on("--decay-half-life-days N", Float, "time_decay半減期日数 (default: 120)") { |v| options[:decay_half_life_days] = v }
  opts.on("--min-sample-weight X", Float, "time_decay最小重み (default: 0.2)") { |v| options[:min_sample_weight] = v }
end
parser.parse!

if options.values_at(:from_date, :to_date).any?(&:nil?)
  warn parser.to_s
  exit 1
end

TimeSeriesCVRunner.new(
  from_date: options[:from_date],
  to_date: options[:to_date],
  train_days: options[:train_days],
  valid_days: options[:valid_days],
  step_days: options[:step_days],
  in_dir: options[:in_dir],
  out_dir: options[:out_dir],
  target_col: options[:target_col],
  drop_features: options[:drop_features],
  weight_mode: options[:weight_mode],
  decay_half_life_days: options[:decay_half_life_days],
  min_sample_weight: options[:min_sample_weight]
).run
