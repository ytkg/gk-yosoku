#!/usr/bin/env ruby
# frozen_string_literal: true

require "csv"
require "date"
require "fileutils"
require "json"
require "optparse"
require_relative "lib/duckdb_runner"

class DuckDBParityValidator
  REQUIRED_SUMMARY_HEADERS = %w[
    csv_rows
    parquet_rows
    csv_only_keys
    parquet_only_keys
    rank_diff
    top1_diff
    top3_diff
  ].freeze

  def initialize(from_date:, to_date:, csv_features_dir:, lake_dir:, feature_set_version:, report_dir:, db_path:)
    @from_date = Date.iso8601(from_date)
    @to_date = Date.iso8601(to_date)
    raise ArgumentError, "from_date must be <= to_date" if @from_date > @to_date

    @csv_features_dir = csv_features_dir
    @lake_dir = lake_dir
    @feature_set_version = feature_set_version
    @report_dir = report_dir
    @db_path = db_path
  end

  def run
    check_duckdb!
    date_stamp = Time.now.strftime("%Y%m%d")
    report_root = File.join(@report_dir, date_stamp)
    FileUtils.mkdir_p(report_root)

    summaries = []
    failed_dates = []
    (@from_date..@to_date).each do |date|
      summary = validate_date(date, report_root)
      summaries << summary
      failed_dates << date.iso8601 unless summary["ok"]
    end

    overall = {
      "from_date" => @from_date.iso8601,
      "to_date" => @to_date.iso8601,
      "dates" => summaries,
      "failed_dates" => failed_dates,
      "ok" => failed_dates.empty?
    }
    summary_path = File.join(report_root, "summary.json")
    File.write(summary_path, JSON.pretty_generate(overall))
    warn "report=#{summary_path}"
    raise "duckdb parity failed: #{failed_dates.join(',')}" unless overall["ok"]
  end

  private

  def check_duckdb!
    GK::DuckDBRunner.ensure_duckdb!(
      message: "duckdb command not found. Please install duckdb CLI in Docker image."
    )
  end

  def validate_date(date, report_root)
    ymd = date.strftime("%Y%m%d")
    iso = date.iso8601
    csv_path = File.join(@csv_features_dir, "features_#{ymd}.csv")
    parquet_path = File.join(
      @lake_dir,
      "features",
      "feature_set=#{@feature_set_version}",
      "race_date=#{iso}",
      "features_#{ymd}.parquet"
    )
    raise "not found: #{csv_path}" unless File.exist?(csv_path)
    raise "not found: #{parquet_path}" unless File.exist?(parquet_path)

    day_dir = File.join(report_root, iso)
    FileUtils.mkdir_p(day_dir)
    summary_csv = File.join(day_dir, "summary.csv")
    diff_csv = File.join(day_dir, "diff_samples.csv")

    sql = <<~SQL
      CREATE OR REPLACE TEMP VIEW csv_src AS
      SELECT *
      FROM read_csv_auto(#{GK::DuckDBRunner.sql_quote(csv_path)}, HEADER=TRUE);

      CREATE OR REPLACE TEMP VIEW pq_src AS
      SELECT *
      FROM read_parquet(#{GK::DuckDBRunner.sql_quote(parquet_path)});

      COPY (
        WITH key_diff_csv_only AS (
          SELECT race_id, car_number FROM csv_src
          EXCEPT
          SELECT race_id, car_number FROM pq_src
        ),
        key_diff_pq_only AS (
          SELECT race_id, car_number FROM pq_src
          EXCEPT
          SELECT race_id, car_number FROM csv_src
        ),
        joined AS (
          SELECT
            COALESCE(c.race_id, p.race_id) AS race_id,
            COALESCE(c.car_number, p.car_number) AS car_number,
            c.rank AS c_rank,
            p.rank AS p_rank,
            c.top1 AS c_top1,
            p.top1 AS p_top1,
            c.top3 AS c_top3,
            p.top3 AS p_top3
          FROM csv_src c
          FULL OUTER JOIN pq_src p
            ON c.race_id = p.race_id AND c.car_number = p.car_number
        )
        SELECT
          (SELECT COUNT(*) FROM csv_src) AS csv_rows,
          (SELECT COUNT(*) FROM pq_src) AS parquet_rows,
          (SELECT COUNT(*) FROM key_diff_csv_only) AS csv_only_keys,
          (SELECT COUNT(*) FROM key_diff_pq_only) AS parquet_only_keys,
          (SELECT COUNT(*) FROM joined WHERE COALESCE(c_rank, '') <> COALESCE(p_rank, '')) AS rank_diff,
          (SELECT COUNT(*) FROM joined WHERE COALESCE(c_top1, '') <> COALESCE(p_top1, '')) AS top1_diff,
          (SELECT COUNT(*) FROM joined WHERE COALESCE(c_top3, '') <> COALESCE(p_top3, '')) AS top3_diff
      ) TO #{GK::DuckDBRunner.sql_quote(summary_csv)} (HEADER, DELIMITER ',');

      COPY (
        WITH joined AS (
          SELECT
            COALESCE(c.race_id, p.race_id) AS race_id,
            COALESCE(c.car_number, p.car_number) AS car_number,
            c.rank AS c_rank,
            p.rank AS p_rank,
            c.top1 AS c_top1,
            p.top1 AS p_top1,
            c.top3 AS c_top3,
            p.top3 AS p_top3
          FROM csv_src c
          FULL OUTER JOIN pq_src p
            ON c.race_id = p.race_id AND c.car_number = p.car_number
        )
        SELECT *
        FROM joined
        WHERE COALESCE(c_rank, '') <> COALESCE(p_rank, '')
           OR COALESCE(c_top1, '') <> COALESCE(p_top1, '')
           OR COALESCE(c_top3, '') <> COALESCE(p_top3, '')
        ORDER BY race_id, car_number
        LIMIT 100
      ) TO #{GK::DuckDBRunner.sql_quote(diff_csv)} (HEADER, DELIMITER ',');
    SQL

    GK::DuckDBRunner.run_sql!(db_path: @db_path, sql: sql)
    row = CSV.read(summary_csv, headers: true).first&.to_h || {}
    missing = REQUIRED_SUMMARY_HEADERS.reject { |h| row.key?(h) }
    raise "invalid summary headers: #{missing.join(',')}" unless missing.empty?
    metric = row.transform_values(&:to_i)
    ok = metric.values.all?(&:zero?) || (
      metric["csv_rows"] == metric["parquet_rows"] &&
      metric["csv_only_keys"].zero? &&
      metric["parquet_only_keys"].zero? &&
      metric["rank_diff"].zero? &&
      metric["top1_diff"].zero? &&
      metric["top3_diff"].zero?
    )
    {
      "date" => iso,
      "csv_path" => csv_path,
      "parquet_path" => parquet_path,
      "summary_csv" => summary_csv,
      "diff_csv" => diff_csv,
      "metrics" => metric,
      "ok" => ok
    }
  end
end

options = {
  from_date: nil,
  to_date: nil,
  csv_features_dir: File.join("data", "features"),
  lake_dir: File.join("data", "lake"),
  feature_set_version: "v1",
  report_dir: File.join("reports", "duckdb_validation"),
  db_path: File.join("data", "duckdb", "gk_yosoku.duckdb")
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: ruby scripts/validate_duckdb_parity.rb --from-date YYYY-MM-DD --to-date YYYY-MM-DD"
  opts.on("--from-date DATE", "開始日 (YYYY-MM-DD)") { |v| options[:from_date] = v }
  opts.on("--to-date DATE", "終了日 (YYYY-MM-DD)") { |v| options[:to_date] = v }
  opts.on("--csv-features-dir DIR", "CSV features ディレクトリ") { |v| options[:csv_features_dir] = v }
  opts.on("--lake-dir DIR", "Parquet 入力ルート") { |v| options[:lake_dir] = v }
  opts.on("--feature-set-version NAME", "feature set version (default: v1)") { |v| options[:feature_set_version] = v }
  opts.on("--report-dir DIR", "検証レポート出力先") { |v| options[:report_dir] = v }
  opts.on("--db-path PATH", "DuckDB DB ファイルパス") { |v| options[:db_path] = v }
end
parser.parse!

if options.values_at(:from_date, :to_date).any?(&:nil?)
  warn parser.to_s
  exit 1
end

DuckDBParityValidator.new(
  from_date: options[:from_date],
  to_date: options[:to_date],
  csv_features_dir: options[:csv_features_dir],
  lake_dir: options[:lake_dir],
  feature_set_version: options[:feature_set_version],
  report_dir: options[:report_dir],
  db_path: options[:db_path]
).run
