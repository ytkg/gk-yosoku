#!/usr/bin/env ruby
# frozen_string_literal: true

require "date"
require "fileutils"
require "optparse"
require_relative "lib/duckdb_runner"

class DuckDBFeatureSplitter
  TEMPLATE_PATH = File.expand_path("../sql/split_train_valid.sql", __dir__)

  def initialize(from_date:, to_date:, train_to:, lake_dir:, feature_set_version:, out_dir:, mart_dir:, db_path:, sql_template:)
    @from_date = Date.iso8601(from_date)
    @to_date = Date.iso8601(to_date)
    @train_to = Date.iso8601(train_to)
    raise ArgumentError, "from_date must be <= to_date" if @from_date > @to_date
    raise ArgumentError, "train_to must be within from_date..to_date" if @train_to < @from_date || @train_to >= @to_date

    @lake_dir = lake_dir
    @feature_set_version = feature_set_version
    @out_dir = out_dir
    @mart_dir = mart_dir
    @db_path = db_path
    @sql_template = sql_template
  end

  def run
    check_duckdb!
    FileUtils.mkdir_p(@out_dir)
    split_id = "#{@from_date.strftime('%Y%m%d')}_#{@to_date.strftime('%Y%m%d')}_train_to_#{@train_to.strftime('%Y%m%d')}"
    mart_split_dir = File.join(@mart_dir, "split_id=#{split_id}")
    FileUtils.mkdir_p(mart_split_dir)

    train_csv = File.join(@out_dir, "train.csv")
    valid_csv = File.join(@out_dir, "valid.csv")
    train_parquet = File.join(mart_split_dir, "train.parquet")
    valid_parquet = File.join(mart_split_dir, "valid.parquet")

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
      train_to: @train_to.iso8601,
      train_csv: train_csv,
      valid_csv: valid_csv,
      train_parquet: train_parquet,
      valid_parquet: valid_parquet
    )

    GK::DuckDBRunner.run_sql!(db_path: @db_path, sql: sql)
    warn "split_id=#{split_id} train_csv=#{train_csv} valid_csv=#{valid_csv}"
    warn "train_parquet=#{train_parquet}"
    warn "valid_parquet=#{valid_parquet}"
  end

  private

  def check_duckdb!
    GK::DuckDBRunner.ensure_duckdb!(
      message: "duckdb command not found. Please install duckdb CLI in Docker image."
    )
  end

  def build_sql(features_glob:, from_date:, to_date:, train_to:, train_csv:, valid_csv:, train_parquet:, valid_parquet:)
    template = File.read(@sql_template, encoding: "UTF-8")
    {
      "features_glob" => features_glob,
      "from_date" => from_date,
      "to_date" => to_date,
      "train_to" => train_to,
      "train_csv" => train_csv,
      "valid_csv" => valid_csv,
      "train_parquet" => train_parquet,
      "valid_parquet" => valid_parquet
    }.each do |key, value|
      template = template.gsub("{{#{key}}}", value.to_s.gsub("'", "''"))
    end
    template
  end
end

options = {
  from_date: nil,
  to_date: nil,
  train_to: nil,
  lake_dir: File.join("data", "lake"),
  feature_set_version: "v1",
  out_dir: File.join("data", "ml"),
  mart_dir: File.join("data", "marts", "train_valid"),
  db_path: File.join("data", "duckdb", "gk_yosoku.duckdb"),
  sql_template: DuckDBFeatureSplitter::TEMPLATE_PATH
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: ruby scripts/split_features_duckdb.rb --from-date YYYY-MM-DD --to-date YYYY-MM-DD --train-to YYYY-MM-DD"
  opts.on("--from-date DATE", "開始日 (YYYY-MM-DD)") { |v| options[:from_date] = v }
  opts.on("--to-date DATE", "終了日 (YYYY-MM-DD)") { |v| options[:to_date] = v }
  opts.on("--train-to DATE", "学習データの最終日 (YYYY-MM-DD)") { |v| options[:train_to] = v }
  opts.on("--lake-dir DIR", "Parquet 入力ルート") { |v| options[:lake_dir] = v }
  opts.on("--feature-set-version NAME", "feature set version (default: v1)") { |v| options[:feature_set_version] = v }
  opts.on("--out-dir DIR", "train/valid CSV 出力先") { |v| options[:out_dir] = v }
  opts.on("--mart-dir DIR", "train/valid Parquet 出力先") { |v| options[:mart_dir] = v }
  opts.on("--db-path PATH", "DuckDB DB ファイルパス") { |v| options[:db_path] = v }
  opts.on("--sql-template PATH", "split SQL テンプレートファイル") { |v| options[:sql_template] = v }
end
parser.parse!

if options.values_at(:from_date, :to_date, :train_to).any?(&:nil?)
  warn parser.to_s
  exit 1
end

DuckDBFeatureSplitter.new(
  from_date: options[:from_date],
  to_date: options[:to_date],
  train_to: options[:train_to],
  lake_dir: options[:lake_dir],
  feature_set_version: options[:feature_set_version],
  out_dir: options[:out_dir],
  mart_dir: options[:mart_dir],
  db_path: options[:db_path],
  sql_template: options[:sql_template]
).run
