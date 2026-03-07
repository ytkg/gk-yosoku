#!/usr/bin/env ruby
# frozen_string_literal: true

require "csv"
require "json"
require "optparse"
require_relative "lib/parquet_materializer"

class ExoticEvaluator
  def initialize(actual_csv:, actual_parquet:, db_path:, exacta_csv:, trifecta_csv:, out_path:, ns:, payout_csv:, unit:)
    @actual_csv = actual_csv
    @actual_parquet = actual_parquet
    @db_path = db_path
    @exacta_csv = exacta_csv
    @trifecta_csv = trifecta_csv
    @out_path = out_path
    @ns = ns.sort.uniq
    @payout_csv = payout_csv
    @unit = unit
  end

  def run
    validate_input_options!
    actual_by_race = build_actual_by_race
    exacta_by_race = read_pred_by_race(@exacta_csv, :exacta)
    trifecta_by_race = read_pred_by_race(@trifecta_csv, :trifecta)
    payout_index = @payout_csv.to_s.empty? ? nil : build_payout_index

    summary = {
      "races" => actual_by_race.size,
      "exacta" => evaluate(actual_by_race, exacta_by_race, :exacta, payout_index),
      "trifecta" => evaluate(actual_by_race, trifecta_by_race, :trifecta, payout_index)
    }
    File.write(@out_path, JSON.pretty_generate(summary))

    warn "races=#{summary['races']}"
    warn "exacta_hit@1=#{format('%.6f', summary['exacta']['hit_at']['1'])}"
    warn "trifecta_hit@1=#{format('%.6f', summary['trifecta']['hit_at']['1'])}"
    warn "summary=#{@out_path}"
  end

  private

  def validate_input_options!
    actual_parquet_present = !(@actual_parquet.nil? || @actual_parquet.empty?)
    actual_csv_present = !(@actual_csv.nil? || @actual_csv.empty?)

    if actual_parquet_present
      warn "actual-csv is ignored because actual-parquet is set" if actual_csv_present
      return
    end

    raise "actual-csv or actual-parquet is required" unless actual_csv_present

    warn "actual input mode=csv (compatibility mode). Use --actual-parquet for standard v2 flow."
  end

  def build_actual_by_race
    rows = CSV.read(resolved_actual_csv, headers: true, encoding: "UTF-8").map(&:to_h)
    grouped = rows.group_by { |r| r["race_id"] }
    grouped.each_with_object({}) do |(race_id, rs), h|
      normal_rows = rs.select { |r| r["rank"].to_s.match?(/\A[1-7]\z/) }
      next unless normal_rows.size >= 3

      sorted = normal_rows.sort_by { |r| r["rank"].to_i }
      first = sorted[0]["car_number"].to_i
      second = sorted[1]["car_number"].to_i
      third = sorted[2]["car_number"].to_i
      h[race_id] = {
        exacta: [first, second],
        trifecta: [first, second, third]
      }
    end
  end

  def resolved_actual_csv
    return @actual_csv if @actual_parquet.nil? || @actual_parquet.empty?

    warn "actual input mode=parquet"
    materialized = File.join(File.dirname(@out_path), "actual_from_parquet.csv")
    materialize_parquet_to_csv(@actual_parquet, materialized)
  end

  def materialize_parquet_to_csv(parquet_path, out_csv_path)
    GK::ParquetMaterializer.to_csv!(
      parquet_path: parquet_path,
      out_csv_path: out_csv_path,
      db_path: @db_path
    )
  end

  def read_pred_by_race(path, kind)
    rows = CSV.read(path, headers: true, encoding: "UTF-8").map(&:to_h)
    rows.group_by { |r| r["race_id"] }.transform_values do |rs|
      sorted = rs.sort_by { |r| -r["score"].to_f }
      if kind == :exacta
        sorted.map { |r| [r["first_car_number"].to_i, r["second_car_number"].to_i] }
      else
        sorted.map { |r| [r["first_car_number"].to_i, r["second_car_number"].to_i, r["third_car_number"].to_i] }
      end
    end
  end

  def evaluate(actual_by_race, pred_by_race, kind, payout_index)
    races = actual_by_race.keys
    hit_at = {}
    roi_at = {}
    races_with_pred = 0

    @ns.each do |n|
      hit = 0
      total_cost = 0
      total_return = 0
      races.each do |race_id|
        pred = pred_by_race[race_id]
        next if pred.nil? || pred.empty?

        races_with_pred += 1 if n == @ns.first
        picked = pred.first(n)
        actual = actual_by_race[race_id][kind]
        is_hit = picked.include?(actual)
        hit += 1 if is_hit

        next if payout_index.nil?

        total_cost += @unit * picked.size
        next unless is_hit

        key = [race_id, kind.to_s, actual.join("-")]
        total_return += payout_index.fetch(key, 0)
      end
      denom = races.size.zero? ? 1 : races.size
      hit_at[n.to_s] = hit.to_f / denom
      unless payout_index.nil?
        roi_at[n.to_s] = total_cost.zero? ? 0.0 : total_return.to_f / total_cost
      end
    end

    out = {
      "races_total" => races.size,
      "races_with_pred" => races_with_pred,
      "hit_at" => hit_at
    }
    out["roi_at"] = roi_at unless payout_index.nil?
    out
  end

  def build_payout_index
    rows = CSV.read(@payout_csv, headers: true, encoding: "UTF-8").map(&:to_h)
    rows.each_with_object({}) do |r, h|
      race_id = r["race_id"].to_s
      bet_type = r["bet_type"].to_s
      combination = r["combination"].to_s
      payout = r["payout"].to_i
      next if race_id.empty? || bet_type.empty? || combination.empty?

      h[[race_id, bet_type, combination]] = payout
    end
  end
end

options = {
  actual_csv: nil,
  actual_parquet: nil,
  db_path: File.join("data", "duckdb", "gk_yosoku.duckdb"),
  exacta_csv: File.join("data", "ml", "exacta_pred.csv"),
  trifecta_csv: File.join("data", "ml", "trifecta_pred.csv"),
  out_path: File.join("data", "ml", "exotic_eval_summary.json"),
  ns: [1, 3, 5, 10, 20],
  payout_csv: "",
  unit: 100
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: ruby scripts/evaluate_exotics.rb [options]"
  opts.on("--actual-csv PATH", "actual results CSV (compatibility mode, default: data/ml/valid.csv)") { |v| options[:actual_csv] = v }
  opts.on("--actual-parquet PATH", "actual results parquet (recommended)") { |v| options[:actual_parquet] = v }
  opts.on("--db-path PATH", "DuckDB DB file path for parquet input") { |v| options[:db_path] = v }
  opts.on("--exacta-csv PATH", "exacta prediction CSV (default: data/ml/exacta_pred.csv)") { |v| options[:exacta_csv] = v }
  opts.on("--trifecta-csv PATH", "trifecta prediction CSV (default: data/ml/trifecta_pred.csv)") { |v| options[:trifecta_csv] = v }
  opts.on("--out PATH", "output summary JSON path (default: data/ml/exotic_eval_summary.json)") { |v| options[:out_path] = v }
  opts.on("--ns LIST", "comma-separated hit@N list, e.g. 1,3,5,10,20") { |v| options[:ns] = v.split(",").map(&:to_i).select { |n| n > 0 } }
  opts.on("--payout-csv PATH", "optional payout CSV (race_id,bet_type,combination,payout)") { |v| options[:payout_csv] = v }
  opts.on("--unit N", Integer, "bet unit for ROI calculation (default: 100)") { |v| options[:unit] = v }
end
parser.parse!

raise "ns is empty" if options[:ns].empty?

ExoticEvaluator.new(
  actual_csv: options[:actual_csv],
  actual_parquet: options[:actual_parquet],
  db_path: options[:db_path],
  exacta_csv: options[:exacta_csv],
  trifecta_csv: options[:trifecta_csv],
  out_path: options[:out_path],
  ns: options[:ns],
  payout_csv: options[:payout_csv],
  unit: options[:unit]
).run
