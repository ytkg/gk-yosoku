#!/usr/bin/env ruby
# frozen_string_literal: true

require "csv"
require "date"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "rbconfig"
require_relative "lib/duckdb_runner"
require_relative "lib/feature_schema"
require_relative "lib/lightgbm_utils"
require_relative "lib/model_manifest"

class LightGBMTrainer
  WEIGHT_MODES = %w[none time_decay].freeze

  def initialize(train_csv:, valid_csv:, train_parquet:, valid_parquet:, db_path:, out_dir:, num_iterations:, learning_rate:, num_leaves:, min_data_in_leaf:, early_stopping_round:, target_col:, drop_features:, weight_mode:, decay_half_life_days:, min_sample_weight:)
    @train_csv = train_csv
    @valid_csv = valid_csv
    @train_parquet = train_parquet
    @valid_parquet = valid_parquet
    @db_path = db_path
    @out_dir = out_dir
    @num_iterations = num_iterations
    @learning_rate = learning_rate
    @num_leaves = num_leaves
    @min_data_in_leaf = min_data_in_leaf
    @early_stopping_round = early_stopping_round
    @target_col = target_col
    @weight_mode = weight_mode
    @decay_half_life_days = decay_half_life_days.to_f
    @min_sample_weight = min_sample_weight.to_f
    @feature_columns = GK::FeatureSchema.feature_columns(drop_features)
    @categorical_features = GK::FeatureSchema.categorical_features_for(@feature_columns)
    FileUtils.mkdir_p(@out_dir)
  end

  def run
    check_lightgbm!
    validate_input_options!

    train_rows = CSV.read(resolved_train_csv, headers: true, encoding: "UTF-8").map(&:to_h)
    valid_rows = CSV.read(resolved_valid_csv, headers: true, encoding: "UTF-8").map(&:to_h)
    raise "empty train rows" if train_rows.empty?
    raise "empty valid rows" if valid_rows.empty?
    raise "missing target column: #{@target_col}" unless train_rows.first.key?(@target_col)
    validate_weight_options!

    encoders = build_encoders(train_rows)
    write_encoder(encoders)

    train_data_path = File.join(@out_dir, "train.tsv")
    valid_data_path = File.join(@out_dir, "valid.tsv")
    train_weights = build_train_weights(train_rows)
    write_lgbm_tsv(train_data_path, train_rows, encoders, weights: train_weights)
    write_lgbm_tsv(valid_data_path, valid_rows, encoders)

    conf_path = File.join(@out_dir, "lightgbm.conf")
    model_path = File.join(@out_dir, "model.txt")
    metric_path = File.join(@out_dir, "train_metric.txt")
    write_config(conf_path, train_data_path, valid_data_path, model_path, metric_path, weighted: !train_weights.nil?)

    run_lightgbm(conf_path)
    write_manifest(train_rows, valid_rows, model_path)
    update_manifest_metrics!(model_path)
    warn "model=#{model_path}"
    warn "metric=#{metric_path}"
  end

  private

  def check_lightgbm!
    GK::LightGBMUtils.ensure_lightgbm!(message: "lightgbm command not found. Please install LightGBM CLI in Docker image.")
  end

  def resolved_train_csv
    warn "input_mode=parquet (train_lightgbm)" unless @train_parquet.nil? || @train_parquet.empty?
    return @train_csv if @train_parquet.nil? || @train_parquet.empty?

    materialize_parquet_to_csv(@train_parquet, File.join(@out_dir, "train_from_parquet.csv"))
  end

  def resolved_valid_csv
    return @valid_csv if @valid_parquet.nil? || @valid_parquet.empty?

    materialize_parquet_to_csv(@valid_parquet, File.join(@out_dir, "valid_from_parquet.csv"))
  end

  def materialize_parquet_to_csv(parquet_path, out_csv_path)
    GK::DuckDBRunner.ensure_duckdb!(message: "duckdb command not found for parquet input")
    sql = <<~SQL
      COPY (
        SELECT *
        FROM read_parquet(#{GK::DuckDBRunner.sql_quote(parquet_path)})
      )
      TO #{GK::DuckDBRunner.sql_quote(out_csv_path)}
      (HEADER, DELIMITER ',');
    SQL
    GK::DuckDBRunner.run_sql!(db_path: @db_path, sql: sql)
    out_csv_path
  end

  def validate_input_options!
    train_parquet_present = !(@train_parquet.nil? || @train_parquet.empty?)
    valid_parquet_present = !(@valid_parquet.nil? || @valid_parquet.empty?)
    train_csv_present = !(@train_csv.nil? || @train_csv.empty?)
    valid_csv_present = !(@valid_csv.nil? || @valid_csv.empty?)

    if train_parquet_present && !valid_parquet_present
      raise "valid-parquet is required when train-parquet is set"
    end

    warn "train-csv is ignored because train-parquet is set" if train_parquet_present && train_csv_present
    warn "valid-csv is ignored because valid-parquet is set" if valid_parquet_present && valid_csv_present
  end

  def build_encoders(rows)
    GK::FeatureSchema.build_categorical_encoders(rows, @feature_columns)
  end

  def write_encoder(encoders)
    File.write(File.join(@out_dir, "encoders.json"), JSON.pretty_generate(encoders))
    File.write(File.join(@out_dir, "feature_columns.json"), JSON.pretty_generate(@feature_columns))
  end

  def write_lgbm_tsv(path, rows, encoders, weights: nil)
    File.open(path, "w") do |f|
      rows.each_with_index do |r, idx|
        y = r[@target_col].to_i
        xs = @feature_columns.map do |name|
          if @categorical_features.include?(name)
            (encoders[name][r[name].to_s] || -1).to_s
          else
            GK::FeatureSchema.to_float_string(r[name])
          end
        end
        line = [y]
        line << format("%.10f", weights[idx]) if weights
        f.puts((line + xs).join("\t"))
      end
    end
  end

  def write_config(path, train_data_path, valid_data_path, model_path, metric_path, weighted:)
    conf = <<~CONF
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
    conf += "weight_column=1\n" if weighted
    File.write(path, conf)

    File.write(metric_path, "")
  end

  def validate_weight_options!
    raise "invalid weight mode: #{@weight_mode}" unless WEIGHT_MODES.include?(@weight_mode)
    return if @weight_mode == "none"
    raise "decay_half_life_days must be > 0" if @decay_half_life_days <= 0.0
    raise "min_sample_weight must be > 0" if @min_sample_weight <= 0.0
  end

  def build_train_weights(train_rows)
    return nil if @weight_mode == "none"

    latest = train_rows.map { |r| parse_date(r["race_date"]) }.max
    weights = train_rows.map do |r|
      age_days = (latest - parse_date(r["race_date"])).to_i
      raw = 0.5**(age_days.to_f / @decay_half_life_days)
      [raw, @min_sample_weight].max
    end
    warn format(
      "sample_weight mode=%s half_life=%.1f min=%.3f max=%.3f avg=%.3f",
      @weight_mode,
      @decay_half_life_days,
      weights.min,
      weights.max,
      (weights.sum / weights.size.to_f)
    )
    weights
  end

  def parse_date(value)
    Date.iso8601(value.to_s)
  rescue Date::Error
    raise "invalid race_date for weighting: #{value.inspect}"
  end

  def run_lightgbm(conf_path)
    cmd = ["lightgbm", "config=#{conf_path}"]
    out, err, status = Open3.capture3(*cmd)
    raise "lightgbm failed: #{err}\n#{out}" unless status.success?

    warn out
  end

  def write_manifest(train_rows, valid_rows, model_path)
    train_dates = train_rows.map { |r| parse_date(r["race_date"]) }
    valid_dates = valid_rows.map { |r| parse_date(r["race_date"]) }
    manifest = GK::ModelManifest.build(
      model_id: File.basename(File.dirname(model_path)).to_s.empty? ? "ml" : File.basename(File.dirname(model_path)),
      target_col: @target_col,
      feature_set_version: GK::FeatureSchema::FEATURE_SET_VERSION,
      feature_columns: @feature_columns,
      train_from: train_dates.min.iso8601,
      train_to: train_dates.max.iso8601,
      valid_from: valid_dates.min.iso8601,
      valid_to: valid_dates.max.iso8601,
      metrics: {},
      data_source_mode: infer_input_mode
    )
    manifest["input_mode"] = infer_input_mode
    GK::ModelManifest.validate_required_keys!(manifest)
    path = File.join(@out_dir, "model_manifest.json")
    File.write(path, JSON.pretty_generate(manifest))
  end

  def update_manifest_metrics!(model_path)
    cmd = [
      RbConfig.ruby,
      "scripts/evaluate_lightgbm.rb",
      "--model", model_path,
      "--encoders", File.join(@out_dir, "encoders.json"),
      "--out-dir", @out_dir,
      "--target-col", @target_col
    ]
    if @valid_parquet.nil? || @valid_parquet.empty?
      cmd += ["--valid-csv", @valid_csv]
    else
      cmd += ["--valid-parquet", @valid_parquet, "--db-path", @db_path]
    end
    out, err, status = Open3.capture3(*cmd)
    raise "evaluate_lightgbm failed: #{err}\n#{out}" unless status.success?

    summary_path = File.join(@out_dir, "eval_summary.json")
    summary = JSON.parse(File.read(summary_path, encoding: "UTF-8"))

    manifest_path = File.join(@out_dir, "model_manifest.json")
    manifest = GK::ModelManifest.load(manifest_path) || {}
    manifest["metrics"] = extract_metrics(summary)
    GK::ModelManifest.validate_required_keys!(manifest)
    File.write(manifest_path, JSON.pretty_generate(manifest))
  end

  def extract_metrics(summary)
    summary.slice(
      "auc",
      "winner_hit_rate",
      "top3_exact_match_rate",
      "top3_recall_at3",
      "rows",
      "races"
    )
  end

  def infer_input_mode
    return "parquet" unless @train_parquet.nil? || @train_parquet.empty?

    warn "input_mode=csv (compatibility)" if !@train_csv.nil? && !@train_csv.empty?
    "csv"
  end
end

options = {
  train_csv: File.join("data", "ml", "train.csv"),
  valid_csv: File.join("data", "ml", "valid.csv"),
  train_parquet: nil,
  valid_parquet: nil,
  db_path: File.join("data", "duckdb", "gk_yosoku.duckdb"),
  out_dir: File.join("data", "ml"),
  num_iterations: 200,
  learning_rate: 0.05,
  num_leaves: 31,
  min_data_in_leaf: 20,
  early_stopping_round: 30,
  target_col: "top3",
  drop_features: [],
  weight_mode: "none",
  decay_half_life_days: 120.0,
  min_sample_weight: 0.2
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: ruby scripts/train_lightgbm.rb [options]"
  opts.on("--train-csv PATH", "train.csv path (compatibility mode)") { |v| options[:train_csv] = v }
  opts.on("--valid-csv PATH", "valid.csv path (compatibility mode)") { |v| options[:valid_csv] = v }
  opts.on("--train-parquet PATH", "train parquet path (recommended)") { |v| options[:train_parquet] = v }
  opts.on("--valid-parquet PATH", "valid parquet path (recommended)") { |v| options[:valid_parquet] = v }
  opts.on("--db-path PATH", "DuckDB DB ファイルパス (parquet利用時)") { |v| options[:db_path] = v }
  opts.on("--out-dir DIR", "output dir") { |v| options[:out_dir] = v }
  opts.on("--num-iterations N", Integer, "boosting rounds") { |v| options[:num_iterations] = v }
  opts.on("--learning-rate X", Float, "learning rate") { |v| options[:learning_rate] = v }
  opts.on("--num-leaves N", Integer, "num leaves") { |v| options[:num_leaves] = v }
  opts.on("--min-data-in-leaf N", Integer, "minimum data in leaf") { |v| options[:min_data_in_leaf] = v }
  opts.on("--early-stopping-round N", Integer, "early stopping rounds") { |v| options[:early_stopping_round] = v }
  opts.on("--target-col NAME", "target column name (top3 or top1)") { |v| options[:target_col] = v }
  opts.on("--drop-features LIST", "comma separated feature names to exclude") { |v| options[:drop_features] = v.split(",").map(&:strip).reject(&:empty?) }
  opts.on("--weight-mode MODE", "sample weight mode: none or time_decay (default: none)") { |v| options[:weight_mode] = v }
  opts.on("--decay-half-life-days N", Float, "half life days for time_decay weights (default: 120)") { |v| options[:decay_half_life_days] = v }
  opts.on("--min-sample-weight X", Float, "minimum sample weight for time_decay mode (default: 0.2)") { |v| options[:min_sample_weight] = v }
end
parser.parse!

LightGBMTrainer.new(
  train_csv: options[:train_csv],
  valid_csv: options[:valid_csv],
  train_parquet: options[:train_parquet],
  valid_parquet: options[:valid_parquet],
  db_path: options[:db_path],
  out_dir: options[:out_dir],
  num_iterations: options[:num_iterations],
  learning_rate: options[:learning_rate],
  num_leaves: options[:num_leaves],
  min_data_in_leaf: options[:min_data_in_leaf],
  early_stopping_round: options[:early_stopping_round],
  target_col: options[:target_col],
  drop_features: options[:drop_features],
  weight_mode: options[:weight_mode],
  decay_half_life_days: options[:decay_half_life_days],
  min_sample_weight: options[:min_sample_weight]
).run
