#!/usr/bin/env ruby
# frozen_string_literal: true

require "csv"
require "fileutils"
require "optparse"
require_relative "lib/exacta_feature_schema"

class ExactaFeatureBuilder
  def initialize(train_csv:, valid_csv:, out_dir:)
    @train_csv = train_csv
    @valid_csv = valid_csv
    @out_dir = out_dir
    FileUtils.mkdir_p(@out_dir)
  end

  def run
    build_for_split(@train_csv, File.join(@out_dir, "train.csv"))
    build_for_split(@valid_csv, File.join(@out_dir, "valid.csv"))
  end

  private

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
end

options = {
  train_csv: File.join("data", "ml", "train.csv"),
  valid_csv: File.join("data", "ml", "valid.csv"),
  out_dir: File.join("data", "ml_exacta")
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: ruby scripts/build_exacta_features.rb [options]"
  opts.on("--train-csv PATH", "base train csv (default: data/ml/train.csv)") { |v| options[:train_csv] = v }
  opts.on("--valid-csv PATH", "base valid csv (default: data/ml/valid.csv)") { |v| options[:valid_csv] = v }
  opts.on("--out-dir DIR", "output dir (default: data/ml_exacta)") { |v| options[:out_dir] = v }
end
parser.parse!

ExactaFeatureBuilder.new(
  train_csv: options[:train_csv],
  valid_csv: options[:valid_csv],
  out_dir: options[:out_dir]
).run
