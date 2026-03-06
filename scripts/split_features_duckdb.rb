#!/usr/bin/env ruby
# frozen_string_literal: true

require "date"
require "fileutils"
require "json"
require "optparse"
require_relative "lib/duckdb_runner"

class DuckDBFeatureSplitter
  TEMPLATE_PATH = File.expand_path("../sql/split_train_valid.sql", __dir__)

  def initialize(from_date:, to_date:, train_to:, lake_dir:, feature_set_version:, out_dir:, mart_dir:, db_path:, sql_template:, emit_csv:)
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
    @emit_csv = emit_csv
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
      train_csv_copy_sql: csv_copy_sql(train: true, csv_path: train_csv, train_to: @train_to.iso8601),
      valid_csv_copy_sql: csv_copy_sql(train: false, csv_path: valid_csv, train_to: @train_to.iso8601),
      train_parquet: train_parquet,
      valid_parquet: valid_parquet
    )

    GK::DuckDBRunner.run_sql!(db_path: @db_path, sql: sql)
    write_summary(
      split_id: split_id,
      train_csv: train_csv,
      valid_csv: valid_csv,
      train_parquet: train_parquet,
      valid_parquet: valid_parquet
    )
    warn "split_id=#{split_id} emit_csv=#{@emit_csv} train_csv=#{train_csv} valid_csv=#{valid_csv}"
    warn "train_parquet=#{train_parquet}"
    warn "valid_parquet=#{valid_parquet}"
  end

  private

  def check_duckdb!
    GK::DuckDBRunner.ensure_duckdb!(
      message: "duckdb command not found. Please install duckdb CLI in Docker image."
    )
  end

  def build_sql(features_glob:, from_date:, to_date:, train_to:, train_csv:, valid_csv:, train_csv_copy_sql:, valid_csv_copy_sql:, train_parquet:, valid_parquet:)
    template = File.read(@sql_template, encoding: "UTF-8")
    replacements = {
      "features_glob" => features_glob,
      "from_date" => from_date,
      "to_date" => to_date,
      "train_to" => train_to,
      "train_csv" => train_csv,
      "valid_csv" => valid_csv,
      "train_csv_copy_sql" => train_csv_copy_sql,
      "valid_csv_copy_sql" => valid_csv_copy_sql,
      "train_parquet" => train_parquet,
      "valid_parquet" => valid_parquet
    }
    replacements.each do |key, value|
      replacement =
        if key.end_with?("_copy_sql")
          value.to_s
        else
          value.to_s.gsub("'", "''")
        end
      template = template.gsub("{{#{key}}}", replacement)
    end
    template
  end

  def csv_copy_sql(train:, csv_path:, train_to:)
    return "-- csv output disabled by --emit-csv=false" unless @emit_csv

    op = train ? "<=" : ">"
    <<~SQL
      COPY (
        SELECT *
        FROM features_filtered
        WHERE CAST(race_date AS DATE) #{op} DATE '#{train_to}'
        ORDER BY race_date, venue, CAST(race_number AS INTEGER), CAST(car_number AS INTEGER)
      ) TO '#{csv_path.gsub("'", "''")}' (HEADER, DELIMITER ',');
    SQL
  end

  def write_summary(split_id:, train_csv:, valid_csv:, train_parquet:, valid_parquet:)
    summary = {
      "split_id" => split_id,
      "emit_csv" => @emit_csv,
      "outputs" => {
        "train_csv" => train_csv,
        "valid_csv" => valid_csv,
        "train_parquet" => train_parquet,
        "valid_parquet" => valid_parquet
      }
    }
    File.write(File.join(@out_dir, "split_summary.json"), JSON.pretty_generate(summary))
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
  sql_template: DuckDBFeatureSplitter::TEMPLATE_PATH,
  emit_csv: true
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
  opts.on("--emit-csv BOOL", "CSVを出力するか (default: true)") { |v| options[:emit_csv] = v.to_s.downcase == "true" }
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
  sql_template: options[:sql_template],
  emit_csv: options[:emit_csv]
).run
