#!/usr/bin/env ruby
# frozen_string_literal: true

require "date"
require "fileutils"
require "optparse"
require_relative "lib/duckdb_runner"

class ParquetBootstrap
  def initialize(from_date:, to_date:, in_dir:, lake_dir:, db_path:)
    @from_date = Date.iso8601(from_date)
    @to_date = Date.iso8601(to_date)
    raise ArgumentError, "from_date must be <= to_date" if @from_date > @to_date

    @in_dir = in_dir
    @lake_dir = lake_dir
    @db_path = db_path
  end

  def run
    check_duckdb!
    (@from_date..@to_date).each { |date| materialize_date(date) }
  end

  private

  def check_duckdb!
    GK::DuckDBRunner.ensure_duckdb!(
      message: "duckdb command not found. Please install duckdb CLI in Docker image."
    )
  end

  def materialize_date(date)
    ymd = date.strftime("%Y%m%d")
    iso = date.iso8601
    results_csv = File.join(@in_dir, "girls_results_#{ymd}.csv")
    races_csv = File.join(@in_dir, "girls_races_#{ymd}.csv")

    if File.exist?(results_csv)
      out = File.join(@lake_dir, "raw_results", "race_date=#{iso}", "results_#{ymd}.parquet")
      copy_csv_to_parquet(results_csv, out)
      warn "results csv=#{results_csv} parquet=#{out}"
    else
      warn "skip results (not found): #{results_csv}"
    end

    if File.exist?(races_csv)
      out = File.join(@lake_dir, "races", "race_date=#{iso}", "races_#{ymd}.parquet")
      copy_csv_to_parquet(races_csv, out)
      warn "races csv=#{races_csv} parquet=#{out}"
    else
      warn "skip races (not found): #{races_csv}"
    end
  end

  def copy_csv_to_parquet(csv_path, out_path)
    FileUtils.mkdir_p(File.dirname(out_path))
    sql = <<~SQL
      COPY (
        SELECT
          *,
          UPPER(TRIM(COALESCE(class, ''))) AS class_normalized
        FROM read_csv_auto(#{GK::DuckDBRunner.sql_quote(csv_path)}, HEADER=TRUE)
      )
      TO #{GK::DuckDBRunner.sql_quote(out_path)}
      (FORMAT PARQUET, COMPRESSION ZSTD);
    SQL
    GK::DuckDBRunner.run_sql!(db_path: @db_path, sql: sql)
  end
end

options = {
  from_date: nil,
  to_date: nil,
  in_dir: File.join("data", "raw"),
  lake_dir: File.join("data", "lake"),
  db_path: File.join("data", "duckdb", "gk_yosoku.duckdb")
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: ruby scripts/parquet_bootstrap.rb --from-date YYYY-MM-DD --to-date YYYY-MM-DD"
  opts.on("--from-date DATE", "開始日 (YYYY-MM-DD)") { |v| options[:from_date] = v }
  opts.on("--to-date DATE", "終了日 (YYYY-MM-DD)") { |v| options[:to_date] = v }
  opts.on("--in-dir DIR", "raw CSV の入力ディレクトリ") { |v| options[:in_dir] = v }
  opts.on("--lake-dir DIR", "Parquet 出力ルート") { |v| options[:lake_dir] = v }
  opts.on("--db-path PATH", "DuckDB DB ファイルパス") { |v| options[:db_path] = v }
end
parser.parse!

if options.values_at(:from_date, :to_date).any?(&:nil?)
  warn parser.to_s
  exit 1
end

ParquetBootstrap.new(
  from_date: options[:from_date],
  to_date: options[:to_date],
  in_dir: options[:in_dir],
  lake_dir: options[:lake_dir],
  db_path: options[:db_path]
).run
