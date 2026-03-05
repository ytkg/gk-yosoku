#!/usr/bin/env ruby
# frozen_string_literal: true

require "csv"
require "fileutils"
require "json"
require "open3"
require "optparse"

class LightGBMTuner
  SORTABLE_METRICS = %w[auc winner_hit_rate top3_exact_match_rate top3_recall_at3].freeze

  def initialize(train_csv:, valid_csv:, train_parquet:, valid_parquet:, db_path:, out_dir:, num_iterations:, early_stopping_round:, learning_rates:, num_leaves_list:, min_data_in_leaf_list:, target_col:, drop_features:, sort_metric:, weight_mode:, decay_half_life_days:, min_sample_weight:)
    @train_csv = train_csv
    @valid_csv = valid_csv
    @train_parquet = train_parquet
    @valid_parquet = valid_parquet
    @db_path = db_path
    @out_dir = out_dir
    @num_iterations = num_iterations
    @early_stopping_round = early_stopping_round
    @learning_rates = learning_rates
    @num_leaves_list = num_leaves_list
    @min_data_in_leaf_list = min_data_in_leaf_list
    @target_col = target_col
    @drop_features = drop_features
    @sort_metric = sort_metric
    @weight_mode = weight_mode
    @decay_half_life_days = decay_half_life_days
    @min_sample_weight = min_sample_weight
    FileUtils.mkdir_p(@out_dir)
  end

  def run
    results = []
    trial = 0

    @learning_rates.each do |lr|
      @num_leaves_list.each do |leaves|
        @min_data_in_leaf_list.each do |min_leaf|
          trial += 1
          trial_dir = File.join(@out_dir, format("trial_%03d", trial))
          FileUtils.mkdir_p(trial_dir)

          train!(trial_dir, lr, leaves, min_leaf)
          summary = evaluate!(trial_dir)

          row = {
            "trial" => trial,
            "learning_rate" => lr,
            "num_leaves" => leaves,
            "min_data_in_leaf" => min_leaf,
            "target_col" => @target_col,
            "drop_features" => @drop_features,
            "train_input_mode" => train_input_mode,
            "auc" => summary.fetch("auc"),
            "winner_hit_rate" => summary.fetch("winner_hit_rate")
          }
          row["top3_exact_match_rate"] = summary["top3_exact_match_rate"] if summary.key?("top3_exact_match_rate")
          row["top3_recall_at3"] = summary["top3_recall_at3"] if summary.key?("top3_recall_at3")
          results << row
          warn "trial=#{trial} sort_metric=#{@sort_metric}=#{format('%.6f', row[@sort_metric])} auc=#{format('%.6f', row['auc'])} winner_hit_rate=#{format('%.6f', row['winner_hit_rate'])} lr=#{lr} leaves=#{leaves} min_leaf=#{min_leaf}"
        end
      end
    end

    ranked = results.sort_by do |r|
      [
        -r.fetch(@sort_metric, 0.0),
        -r.fetch("winner_hit_rate", 0.0),
        -r.fetch("auc", 0.0),
        -r.fetch("top3_exact_match_rate", 0.0)
      ]
    end
    write_leaderboard(ranked)
    write_best(ranked.first)

    best = ranked.first
    warn "best_trial=#{best['trial']} sort_metric=#{@sort_metric}=#{format('%.6f', best[@sort_metric])} auc=#{format('%.6f', best['auc'])} winner_hit_rate=#{format('%.6f', best['winner_hit_rate'])}"
  end

  private

  def train!(trial_dir, lr, leaves, min_leaf)
    cmd = [
      "ruby", "scripts/train_lightgbm.rb",
      "--out-dir", trial_dir,
      "--num-iterations", @num_iterations.to_s,
      "--learning-rate", lr.to_s,
      "--num-leaves", leaves.to_s,
      "--min-data-in-leaf", min_leaf.to_s,
      "--early-stopping-round", @early_stopping_round.to_s,
      "--target-col", @target_col,
      "--weight-mode", @weight_mode.to_s,
      "--decay-half-life-days", @decay_half_life_days.to_s,
      "--min-sample-weight", @min_sample_weight.to_s
    ]
    if @train_parquet.nil? || @train_parquet.empty?
      cmd += ["--train-csv", @train_csv]
    else
      cmd += ["--train-parquet", @train_parquet, "--db-path", @db_path]
    end
    if @valid_parquet.nil? || @valid_parquet.empty?
      cmd += ["--valid-csv", @valid_csv]
    else
      cmd += ["--valid-parquet", @valid_parquet, "--db-path", @db_path]
    end
    cmd += ["--drop-features", @drop_features.join(",")] unless @drop_features.empty?
    run_cmd!(cmd)
  end

  def evaluate!(trial_dir)
    cmd = [
      "ruby", "scripts/evaluate_lightgbm.rb",
      "--model", File.join(trial_dir, "model.txt"),
      "--encoders", File.join(trial_dir, "encoders.json"),
      "--out-dir", trial_dir,
      "--target-col", @target_col
    ]
    if @valid_parquet.nil? || @valid_parquet.empty?
      cmd += ["--valid-csv", @valid_csv]
    else
      cmd += ["--valid-parquet", @valid_parquet, "--db-path", @db_path]
    end
    run_cmd!(cmd)

    summary_path = File.join(trial_dir, "eval_summary.json")
    JSON.parse(File.read(summary_path, encoding: "UTF-8"))
  end

  def write_leaderboard(rows)
    headers = %w[
      trial
      learning_rate
      num_leaves
      min_data_in_leaf
      target_col
      drop_features
      train_input_mode
      auc
      winner_hit_rate
      top3_exact_match_rate
      top3_recall_at3
    ]
    path = File.join(@out_dir, "tune_leaderboard.csv")
    CSV.open(path, "w", write_headers: true, headers: headers) do |csv|
      rows.each { |r| csv << headers.map { |h| r[h] } }
    end
  end

  def write_best(best_row)
    File.write(File.join(@out_dir, "best_params.json"), JSON.pretty_generate(best_row))
  end

  def run_cmd!(cmd)
    out, err, status = Open3.capture3(*cmd)
    raise "command failed: #{cmd.join(' ')}\n#{err}\n#{out}" unless status.success?
  end

  def train_input_mode
    return "parquet" unless @train_parquet.nil? || @train_parquet.empty?

    "csv"
  end
end

options = {
  train_csv: File.join("data", "ml", "train.csv"),
  valid_csv: File.join("data", "ml", "valid.csv"),
  train_parquet: nil,
  valid_parquet: nil,
  db_path: File.join("data", "duckdb", "gk_yosoku.duckdb"),
  out_dir: File.join("data", "ml", "tuning"),
  num_iterations: 400,
  early_stopping_round: 30,
  learning_rates: [0.03, 0.05],
  num_leaves_list: [31, 63],
  min_data_in_leaf_list: [20, 40, 80],
  target_col: "top3",
  drop_features: [],
  sort_metric: "auc",
  weight_mode: "none",
  decay_half_life_days: 120.0,
  min_sample_weight: 0.2
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: ruby scripts/tune_lightgbm.rb [options]"
  opts.on("--train-csv PATH", "train.csv path") { |v| options[:train_csv] = v }
  opts.on("--valid-csv PATH", "valid.csv path") { |v| options[:valid_csv] = v }
  opts.on("--train-parquet PATH", "train parquet path (optional)") { |v| options[:train_parquet] = v }
  opts.on("--valid-parquet PATH", "valid parquet path (optional)") { |v| options[:valid_parquet] = v }
  opts.on("--db-path PATH", "DuckDB DBファイル (valid-parquet利用時)") { |v| options[:db_path] = v }
  opts.on("--out-dir DIR", "tuning output dir") { |v| options[:out_dir] = v }
  opts.on("--num-iterations N", Integer, "boosting rounds for each trial") { |v| options[:num_iterations] = v }
  opts.on("--early-stopping-round N", Integer, "early stopping rounds") { |v| options[:early_stopping_round] = v }
  opts.on("--learning-rates LIST", "comma separated float list (e.g. 0.03,0.05)") { |v| options[:learning_rates] = v.split(",").map(&:to_f) }
  opts.on("--num-leaves LIST", "comma separated int list (e.g. 31,63)") { |v| options[:num_leaves_list] = v.split(",").map(&:to_i) }
  opts.on("--min-data-in-leaf LIST", "comma separated int list (e.g. 20,40,80)") { |v| options[:min_data_in_leaf_list] = v.split(",").map(&:to_i) }
  opts.on("--target-col NAME", "target column name (top3 or top1)") { |v| options[:target_col] = v }
  opts.on("--drop-features LIST", "comma separated feature names to exclude") { |v| options[:drop_features] = v.split(",").map(&:strip).reject(&:empty?) }
  opts.on("--sort-metric NAME", "ranking metric: #{LightGBMTuner::SORTABLE_METRICS.join(', ')}") { |v| options[:sort_metric] = v }
  opts.on("--weight-mode MODE", "sample weight mode: none or time_decay") { |v| options[:weight_mode] = v }
  opts.on("--decay-half-life-days N", Float, "half life days for time_decay weights") { |v| options[:decay_half_life_days] = v }
  opts.on("--min-sample-weight X", Float, "minimum sample weight for time_decay weights") { |v| options[:min_sample_weight] = v }
end
parser.parse!

unless LightGBMTuner::SORTABLE_METRICS.include?(options[:sort_metric])
  raise "invalid sort metric: #{options[:sort_metric]}"
end

LightGBMTuner.new(
  train_csv: options[:train_csv],
  valid_csv: options[:valid_csv],
  train_parquet: options[:train_parquet],
  valid_parquet: options[:valid_parquet],
  db_path: options[:db_path],
  out_dir: options[:out_dir],
  num_iterations: options[:num_iterations],
  early_stopping_round: options[:early_stopping_round],
  learning_rates: options[:learning_rates],
  num_leaves_list: options[:num_leaves_list],
  min_data_in_leaf_list: options[:min_data_in_leaf_list],
  target_col: options[:target_col],
  drop_features: options[:drop_features],
  sort_metric: options[:sort_metric],
  weight_mode: options[:weight_mode],
  decay_half_life_days: options[:decay_half_life_days],
  min_sample_weight: options[:min_sample_weight]
).run
