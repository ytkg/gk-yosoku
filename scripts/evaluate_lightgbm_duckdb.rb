#!/usr/bin/env ruby
# frozen_string_literal: true

require "date"
require "fileutils"
require "open3"
require "optparse"
require "rbconfig"
require_relative "lib/duckdb_runner"

class DuckDBLightGBMEvaluator
  TEMPLATE_PATH = File.expand_path("../sql/eval_materialize.sql", __dir__)

  def initialize(model_path:, encoder_path:, out_dir:, target_col:, from_date:, to_date:, lake_dir:, feature_set_version:, db_path:, sql_template:)
    @model_path = model_path
    @encoder_path = encoder_path
    @out_dir = out_dir
    @target_col = target_col
    @from_date = Date.iso8601(from_date)
    @to_date = Date.iso8601(to_date)
    raise ArgumentError, "from_date must be <= to_date" if @from_date > @to_date

    @lake_dir = lake_dir
    @feature_set_version = feature_set_version
    @db_path = db_path
    @sql_template = sql_template
  end

  def run
    check_duckdb!
    FileUtils.mkdir_p(@out_dir)
    valid_csv = materialize_valid_csv
    run_eval!(valid_csv)
  end

  private

  def check_duckdb!
    GK::DuckDBRunner.ensure_duckdb!(
      message: "duckdb command not found. Please install duckdb CLI in Docker image."
    )
  end

  def materialize_valid_csv
    out_csv = File.join(@out_dir, "valid_from_duckdb.csv")
    features_glob = File.join(
      @lake_dir,
      "features",
      "feature_set=#{@feature_set_version}",
      "race_date=*",
      "*.parquet"
    )
    sql = build_sql(
      features_glob: features_glob,
      from_date: @from_date.iso8601,
      to_date: @to_date.iso8601,
      out_csv: out_csv
    )
    GK::DuckDBRunner.run_sql!(db_path: @db_path, sql: sql)
    out_csv
  end

  def run_eval!(valid_csv)
    cmd = [
      RbConfig.ruby,
      "scripts/evaluate_lightgbm.rb",
      "--model", @model_path,
      "--valid-csv", valid_csv,
      "--encoders", @encoder_path,
      "--out-dir", @out_dir,
      "--target-col", @target_col
    ]
    out, err, status = Open3.capture3(*cmd)
    raise "evaluate_lightgbm failed: #{err}\n#{out}" unless status.success?
  end

  def build_sql(features_glob:, from_date:, to_date:, out_csv:)
    template = File.read(@sql_template, encoding: "UTF-8")
    {
      "features_glob" => features_glob,
      "from_date" => from_date,
      "to_date" => to_date,
      "out_csv" => out_csv
    }.each do |key, value|
      template = template.gsub("{{#{key}}}", value.to_s.gsub("'", "''"))
    end
    template
  end
end

options = {
  model_path: File.join("data", "ml", "model.txt"),
  encoder_path: File.join("data", "ml", "encoders.json"),
  out_dir: File.join("data", "ml"),
  target_col: "top3",
  from_date: nil,
  to_date: nil,
  lake_dir: File.join("data", "lake"),
  feature_set_version: "v1",
  db_path: File.join("data", "duckdb", "gk_yosoku.duckdb"),
  sql_template: DuckDBLightGBMEvaluator::TEMPLATE_PATH
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: ruby scripts/evaluate_lightgbm_duckdb.rb --from-date YYYY-MM-DD --to-date YYYY-MM-DD [options]"
  opts.on("--model PATH", "LightGBM model path") { |v| options[:model_path] = v }
  opts.on("--encoders PATH", "encoders.json path") { |v| options[:encoder_path] = v }
  opts.on("--out-dir DIR", "output dir") { |v| options[:out_dir] = v }
  opts.on("--target-col NAME", "target column name (top3 or top1)") { |v| options[:target_col] = v }
  opts.on("--from-date DATE", "開始日 (YYYY-MM-DD)") { |v| options[:from_date] = v }
  opts.on("--to-date DATE", "終了日 (YYYY-MM-DD)") { |v| options[:to_date] = v }
  opts.on("--lake-dir DIR", "Parquet 入力ルート") { |v| options[:lake_dir] = v }
  opts.on("--feature-set-version NAME", "feature set version (default: v1)") { |v| options[:feature_set_version] = v }
  opts.on("--db-path PATH", "DuckDB DB ファイルパス") { |v| options[:db_path] = v }
  opts.on("--sql-template PATH", "eval SQL テンプレートファイル") { |v| options[:sql_template] = v }
end
parser.parse!

if options.values_at(:from_date, :to_date).any?(&:nil?)
  warn parser.to_s
  exit 1
end

DuckDBLightGBMEvaluator.new(
  model_path: options[:model_path],
  encoder_path: options[:encoder_path],
  out_dir: options[:out_dir],
  target_col: options[:target_col],
  from_date: options[:from_date],
  to_date: options[:to_date],
  lake_dir: options[:lake_dir],
  feature_set_version: options[:feature_set_version],
  db_path: options[:db_path],
  sql_template: options[:sql_template]
).run
