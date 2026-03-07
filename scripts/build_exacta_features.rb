#!/usr/bin/env ruby
# frozen_string_literal: true

require "csv"
require "fileutils"
require "optparse"
require_relative "lib/duckdb_runner"
require_relative "lib/parquet_materializer"
require_relative "lib/exacta_feature_schema"

class ExactaFeatureBuilder
  def initialize(train_csv:, valid_csv:, train_parquet:, valid_parquet:, db_path:, out_dir:, emit_parquet:)
    @train_csv = train_csv
    @valid_csv = valid_csv
    @train_parquet = train_parquet
    @valid_parquet = valid_parquet
    @db_path = db_path
    @out_dir = out_dir
    @emit_parquet = emit_parquet
    FileUtils.mkdir_p(@out_dir)
  end

  def run
    validate_input_options!
    train_csv = File.join(@out_dir, "train.csv")
    valid_csv = File.join(@out_dir, "valid.csv")
    build_for_split(resolved_train_csv, train_csv)
    build_for_split(resolved_valid_csv, valid_csv)
    materialize_parquet(train_csv: train_csv, valid_csv: valid_csv) if @emit_parquet
  end

  private

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

  def resolved_train_csv
    return @train_csv if @train_parquet.nil? || @train_parquet.empty?

    materialize_parquet_to_csv(@train_parquet, File.join(@out_dir, "train_from_parquet.csv"))
  end

  def resolved_valid_csv
    return @valid_csv if @valid_parquet.nil? || @valid_parquet.empty?

    materialize_parquet_to_csv(@valid_parquet, File.join(@out_dir, "valid_from_parquet.csv"))
  end

  def materialize_parquet_to_csv(parquet_path, out_csv_path)
    GK::ParquetMaterializer.to_csv!(
      parquet_path: parquet_path,
      out_csv_path: out_csv_path,
      db_path: @db_path
    )
  end

  def build_for_split(in_path, out_path)
    rows = CSV.read(in_path, headers: true, encoding: "UTF-8").map(&:to_h)
    raise "input is empty: #{in_path}" if rows.empty?

    validate_headers!(rows.first.keys, in_path)
    pair_rows = build_pair_rows(rows)
    write_rows(out_path, pair_rows)

    warn "input=#{in_path} races=#{rows.map { |r| r['race_id'] }.uniq.size} rows=#{rows.size} pair_rows=#{pair_rows.size} out=#{out_path}"
  end

  def validate_headers!(headers, path)
    missing = GK::ExactaFeatureSchema::SOURCE_FEATURE_COLUMNS.reject { |h| headers.include?(h) }
    raise "missing required feature columns in #{path}: #{missing.join(',')}" unless missing.empty?
    raise "missing rank in #{path}" unless headers.include?("rank")
  end

  def build_pair_rows(rows)
    grouped = rows.group_by { |r| r["race_id"] }
    grouped.keys.sort.flat_map do |race_id|
      rs = grouped.fetch(race_id).sort_by { |r| r["car_number"].to_i }
      next [] if rs.size < 2

      build_race_pairs(rs)
    end
  end

  def build_race_pairs(race_rows)
    race_rows.flat_map do |first|
      race_rows.map do |second|
        next if first["car_number"] == second["car_number"]

        build_pair_row(first, second)
      end
    end.compact
  end

  def build_pair_row(first, second)
    row = {
      "race_id" => first["race_id"],
      "race_date" => first["race_date"],
      "venue" => first["venue"],
      "race_number" => first["race_number"],
      "first_car_number" => first["car_number"],
      "first_player_name" => first["player_name"],
      "second_car_number" => second["car_number"],
      "second_player_name" => second["player_name"],
      "first_rank" => first["rank"],
      "second_rank" => second["rank"],
      GK::ExactaFeatureSchema::TARGET_COLUMN => exacta_target(first, second).to_s
    }

    GK::ExactaFeatureSchema::SOURCE_FEATURE_COLUMNS.each do |col|
      row["first_#{col}"] = first[col]
      row["second_#{col}"] = second[col]
    end

    GK::ExactaFeatureSchema::SOURCE_NUMERIC_FEATURES.each do |col|
      d = first[col].to_f - second[col].to_f
      row["diff_#{col}"] = format("%.6f", d)
    end

    row
  end

  def exacta_target(first, second)
    first["rank"].to_i == 1 && second["rank"].to_i == 2 ? 1 : 0
  end

  def write_rows(path, rows)
    headers = GK::ExactaFeatureSchema.output_headers
    CSV.open(path, "w", write_headers: true, headers: headers) do |csv|
      rows.each { |r| csv << headers.map { |h| r[h] } }
    end
  end

  def materialize_parquet(train_csv:, valid_csv:)
    GK::DuckDBRunner.ensure_duckdb!(
      message: "duckdb command not found. Please install duckdb CLI in Docker image."
    )
    train_parquet = File.join(@out_dir, "train.parquet")
    valid_parquet = File.join(@out_dir, "valid.parquet")
    sql = <<~SQL
      COPY (SELECT * FROM read_csv_auto('#{escape_sql_path(train_csv)}', HEADER=TRUE)) TO '#{escape_sql_path(train_parquet)}' (FORMAT PARQUET);
      COPY (SELECT * FROM read_csv_auto('#{escape_sql_path(valid_csv)}', HEADER=TRUE)) TO '#{escape_sql_path(valid_parquet)}' (FORMAT PARQUET);
    SQL
    GK::DuckDBRunner.run_sql!(db_path: @db_path, sql: sql)
    warn "parquet_train=#{train_parquet}"
    warn "parquet_valid=#{valid_parquet}"
  end

  def escape_sql_path(path)
    path.to_s.gsub("'", "''")
  end
end

options = {
  train_csv: File.join("data", "ml", "train.csv"),
  valid_csv: File.join("data", "ml", "valid.csv"),
  train_parquet: nil,
  valid_parquet: nil,
  db_path: File.join("data", "duckdb", "gk_yosoku.duckdb"),
  out_dir: File.join("data", "ml_exacta"),
  emit_parquet: false
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: ruby scripts/build_exacta_features.rb [options]"
  opts.on("--train-csv PATH", "base train csv (compatibility mode)") { |v| options[:train_csv] = v }
  opts.on("--valid-csv PATH", "base valid csv (compatibility mode)") { |v| options[:valid_csv] = v }
  opts.on("--train-parquet PATH", "base train parquet (recommended)") { |v| options[:train_parquet] = v }
  opts.on("--valid-parquet PATH", "base valid parquet (recommended)") { |v| options[:valid_parquet] = v }
  opts.on("--db-path PATH", "DuckDB DB path for parquet input") { |v| options[:db_path] = v }
  opts.on("--out-dir DIR", "output dir (default: data/ml_exacta)") { |v| options[:out_dir] = v }
  opts.on("--emit-parquet BOOL", "output train.parquet/valid.parquet (default: false)") { |v| options[:emit_parquet] = v.to_s.downcase == "true" }
end
parser.parse!

ExactaFeatureBuilder.new(
  train_csv: options[:train_csv],
  valid_csv: options[:valid_csv],
  train_parquet: options[:train_parquet],
  valid_parquet: options[:valid_parquet],
  db_path: options[:db_path],
  out_dir: options[:out_dir],
  emit_parquet: options[:emit_parquet]
).run
