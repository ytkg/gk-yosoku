#!/usr/bin/env ruby
# frozen_string_literal: true

require "date"
require "fileutils"
require "open3"
require "optparse"
require "rbconfig"
require_relative "lib/duckdb_runner"

class DuckDBFeatureMaterializer
  TEMPLATE_PATH = File.expand_path("../sql/features_v1.sql", __dir__)

  def initialize(from_date:, to_date:, in_dir:, out_dir:, raw_html_dir:, lake_dir:, db_path:, feature_set_version:, skip_build:, mode:, sql_template:)
    @from_date = Date.iso8601(from_date)
    @to_date = Date.iso8601(to_date)
    raise ArgumentError, "from_date must be <= to_date" if @from_date > @to_date

    @in_dir = in_dir
    @out_dir = out_dir
    @raw_html_dir = raw_html_dir
    @lake_dir = lake_dir
    @db_path = db_path
    @feature_set_version = feature_set_version
    @skip_build = skip_build
    @mode = mode
    @sql_template = sql_template
  end

  def run
    check_duckdb!
    case @mode
    when "csv_bridge"
      run_build_features! unless @skip_build
      (@from_date..@to_date).each { |date| materialize_date(date) }
    when "sql_v1"
      (@from_date..@to_date).each do |date|
        materialize_date_via_sql(date)
        materialize_date(date)
      end
    else
      raise "invalid mode: #{@mode}"
    end
  end

  private

  def check_duckdb!
    GK::DuckDBRunner.ensure_duckdb!(
      message: "duckdb command not found. Please install duckdb CLI in Docker image."
    )
  end

  def run_build_features!
    cmd = [
      RbConfig.ruby,
      "scripts/build_features.rb",
      "--from-date", @from_date.iso8601,
      "--to-date", @to_date.iso8601,
      "--in-dir", @in_dir,
      "--out-dir", @out_dir,
      "--raw-html-dir", @raw_html_dir
    ]
    _out, err, status = Open3.capture3(*cmd)
    raise "build_features failed: #{err}" unless status.success?
  end

  def materialize_date(date)
    ymd = date.strftime("%Y%m%d")
    iso = date.iso8601
    features_csv = File.join(@out_dir, "features_#{ymd}.csv")
    raise "not found: #{features_csv}" unless File.exist?(features_csv)

    out = File.join(
      @lake_dir,
      "features",
      "feature_set=#{@feature_set_version}",
      "race_date=#{iso}",
      "features_#{ymd}.parquet"
    )
    FileUtils.mkdir_p(File.dirname(out))
    sql = <<~SQL
      COPY (
        SELECT *,
               #{GK::DuckDBRunner.sql_quote(@feature_set_version)}::VARCHAR AS feature_set_version
        FROM read_csv_auto(#{GK::DuckDBRunner.sql_quote(features_csv)}, HEADER=TRUE)
      )
      TO #{GK::DuckDBRunner.sql_quote(out)}
      (FORMAT PARQUET, COMPRESSION ZSTD);
    SQL
    GK::DuckDBRunner.run_sql!(db_path: @db_path, sql: sql)
    warn "features csv=#{features_csv} parquet=#{out}"
  end

  def materialize_date_via_sql(date)
    ymd = date.strftime("%Y%m%d")
    features_csv = File.join(@out_dir, "features_#{ymd}.csv")
    FileUtils.mkdir_p(@out_dir)
    sql = build_sql_v1(raw_results_glob: raw_results_glob, target_date: date.iso8601, out_csv: features_csv)
    GK::DuckDBRunner.run_sql!(db_path: @db_path, sql: sql)
    warn "features(sql_v1) csv=#{features_csv}"
  end

  def raw_results_glob
    File.join(@lake_dir, "raw_results", "race_date=*", "*.parquet")
  end

  def build_sql_v1(raw_results_glob:, target_date:, out_csv:)
    template = File.read(@sql_template, encoding: "UTF-8")
    {
      "raw_results_glob" => raw_results_glob,
      "target_date" => target_date,
      "out_csv" => out_csv
    }.each do |key, value|
      template = template.gsub("{{#{key}}}", value.to_s.gsub("'", "''"))
    end
    template
  end
end

options = {
  from_date: nil,
  to_date: nil,
  in_dir: File.join("data", "raw"),
  out_dir: File.join("data", "features"),
  raw_html_dir: File.join("data", "raw_html"),
  lake_dir: File.join("data", "lake"),
  db_path: File.join("data", "duckdb", "gk_yosoku.duckdb"),
  feature_set_version: "v1",
  skip_build: false,
  mode: "csv_bridge",
  sql_template: DuckDBFeatureMaterializer::TEMPLATE_PATH
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: ruby scripts/build_features_duckdb.rb --from-date YYYY-MM-DD --to-date YYYY-MM-DD"
  opts.on("--from-date DATE", "開始日 (YYYY-MM-DD)") { |v| options[:from_date] = v }
  opts.on("--to-date DATE", "終了日 (YYYY-MM-DD)") { |v| options[:to_date] = v }
  opts.on("--in-dir DIR", "raw CSV の入力ディレクトリ") { |v| options[:in_dir] = v }
  opts.on("--out-dir DIR", "features CSV の出力ディレクトリ") { |v| options[:out_dir] = v }
  opts.on("--raw-html-dir DIR", "raw HTML ディレクトリ") { |v| options[:raw_html_dir] = v }
  opts.on("--lake-dir DIR", "Parquet 出力ルート") { |v| options[:lake_dir] = v }
  opts.on("--db-path PATH", "DuckDB DB ファイルパス") { |v| options[:db_path] = v }
  opts.on("--feature-set-version NAME", "feature set version (default: v1)") { |v| options[:feature_set_version] = v }
  opts.on("--skip-build", "build_features.rb の実行をスキップ") { options[:skip_build] = true }
  opts.on("--mode MODE", "csv_bridge or sql_v1 (default: csv_bridge)") { |v| options[:mode] = v }
  opts.on("--sql-template PATH", "sql_v1 用SQLテンプレート") { |v| options[:sql_template] = v }
end
parser.parse!

if options.values_at(:from_date, :to_date).any?(&:nil?)
  warn parser.to_s
  exit 1
end

DuckDBFeatureMaterializer.new(
  from_date: options[:from_date],
  to_date: options[:to_date],
  in_dir: options[:in_dir],
  out_dir: options[:out_dir],
  raw_html_dir: options[:raw_html_dir],
  lake_dir: options[:lake_dir],
  db_path: options[:db_path],
  feature_set_version: options[:feature_set_version],
  skip_build: options[:skip_build],
  mode: options[:mode],
  sql_template: options[:sql_template]
).run
