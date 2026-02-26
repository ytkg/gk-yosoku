#!/usr/bin/env ruby
# frozen_string_literal: true

require "csv"
require "fileutils"
require "json"
require "open3"
require "optparse"

class LightGBMTrainer
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

  def initialize(train_csv:, valid_csv:, out_dir:, num_iterations:, learning_rate:, num_leaves:, min_data_in_leaf:, early_stopping_round:, target_col:)
    @train_csv = train_csv
    @valid_csv = valid_csv
    @out_dir = out_dir
    @num_iterations = num_iterations
    @learning_rate = learning_rate
    @num_leaves = num_leaves
    @min_data_in_leaf = min_data_in_leaf
    @early_stopping_round = early_stopping_round
    @target_col = target_col
    FileUtils.mkdir_p(@out_dir)
  end

  def run
    check_lightgbm!

    train_rows = CSV.read(@train_csv, headers: true, encoding: "UTF-8").map(&:to_h)
    valid_rows = CSV.read(@valid_csv, headers: true, encoding: "UTF-8").map(&:to_h)
    raise "empty train rows" if train_rows.empty?
    raise "empty valid rows" if valid_rows.empty?
    raise "missing target column: #{@target_col}" unless train_rows.first.key?(@target_col)

    encoders = build_encoders(train_rows)
    write_encoder(encoders)

    train_data_path = File.join(@out_dir, "train.tsv")
    valid_data_path = File.join(@out_dir, "valid.tsv")
    write_lgbm_tsv(train_data_path, train_rows, encoders)
    write_lgbm_tsv(valid_data_path, valid_rows, encoders)

    conf_path = File.join(@out_dir, "lightgbm.conf")
    model_path = File.join(@out_dir, "model.txt")
    metric_path = File.join(@out_dir, "train_metric.txt")
    write_config(conf_path, train_data_path, valid_data_path, model_path, metric_path)

    run_lightgbm(conf_path)
    warn "model=#{model_path}"
    warn "metric=#{metric_path}"
  end

  private

  def check_lightgbm!
    return if system("command -v lightgbm >/dev/null 2>&1")

    raise "lightgbm command not found. Please install LightGBM CLI in Docker image."
  end

  def build_encoders(rows)
    CATEGORICAL_FEATURES.to_h do |f|
      values = rows.map { |r| r[f].to_s }.uniq.sort
      [f, values.each_with_index.to_h { |v, i| [v, i] }]
    end
  end

  def write_encoder(encoders)
    File.write(File.join(@out_dir, "encoders.json"), JSON.pretty_generate(encoders))
  end

  def write_lgbm_tsv(path, rows, encoders)
    File.open(path, "w") do |f|
      rows.each do |r|
        y = r[@target_col].to_i
        xs = FEATURE_COLUMNS.map do |name|
          if CATEGORICAL_FEATURES.include?(name)
            (encoders[name][r[name].to_s] || -1).to_s
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

  def write_config(path, train_data_path, valid_data_path, model_path, metric_path)
    File.write(path, <<~CONF)
      task=train
      objective=binary
      metric=binary_logloss,auc
      data=#{train_data_path}
      valid_data=#{valid_data_path}
      output_model=#{model_path}
      num_iterations=#{@num_iterations}
      learning_rate=#{@learning_rate}
      num_leaves=#{@num_leaves}
      min_data_in_leaf=#{@min_data_in_leaf}
      verbosity=1
      header=false
      first_metric_only=false
      early_stopping_round=#{@early_stopping_round}
    CONF

    File.write(metric_path, "")
  end

  def run_lightgbm(conf_path)
    cmd = ["lightgbm", "config=#{conf_path}"]
    out, err, status = Open3.capture3(*cmd)
    raise "lightgbm failed: #{err}\n#{out}" unless status.success?

    warn out
  end
end

options = {
  train_csv: File.join("data", "ml", "train.csv"),
  valid_csv: File.join("data", "ml", "valid.csv"),
  out_dir: File.join("data", "ml"),
  num_iterations: 200,
  learning_rate: 0.05,
  num_leaves: 31,
  min_data_in_leaf: 20,
  early_stopping_round: 30,
  target_col: "top3"
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: ruby scripts/train_lightgbm.rb [options]"
  opts.on("--train-csv PATH", "train.csv path") { |v| options[:train_csv] = v }
  opts.on("--valid-csv PATH", "valid.csv path") { |v| options[:valid_csv] = v }
  opts.on("--out-dir DIR", "output dir") { |v| options[:out_dir] = v }
  opts.on("--num-iterations N", Integer, "boosting rounds") { |v| options[:num_iterations] = v }
  opts.on("--learning-rate X", Float, "learning rate") { |v| options[:learning_rate] = v }
  opts.on("--num-leaves N", Integer, "num leaves") { |v| options[:num_leaves] = v }
  opts.on("--min-data-in-leaf N", Integer, "minimum data in leaf") { |v| options[:min_data_in_leaf] = v }
  opts.on("--early-stopping-round N", Integer, "early stopping rounds") { |v| options[:early_stopping_round] = v }
  opts.on("--target-col NAME", "target column name (top3 or top1)") { |v| options[:target_col] = v }
end
parser.parse!

LightGBMTrainer.new(
  train_csv: options[:train_csv],
  valid_csv: options[:valid_csv],
  out_dir: options[:out_dir],
  num_iterations: options[:num_iterations],
  learning_rate: options[:learning_rate],
  num_leaves: options[:num_leaves],
  min_data_in_leaf: options[:min_data_in_leaf],
  early_stopping_round: options[:early_stopping_round],
  target_col: options[:target_col]
).run
