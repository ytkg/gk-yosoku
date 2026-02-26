#!/usr/bin/env ruby
# frozen_string_literal: true

require "csv"
require "json"
require "optparse"

class ExoticEvaluator
  def initialize(actual_csv:, exacta_csv:, trifecta_csv:, out_path:, ns:)
    @actual_csv = actual_csv
    @exacta_csv = exacta_csv
    @trifecta_csv = trifecta_csv
    @out_path = out_path
    @ns = ns.sort.uniq
  end

  def run
    actual_by_race = build_actual_by_race
    exacta_by_race = read_pred_by_race(@exacta_csv, :exacta)
    trifecta_by_race = read_pred_by_race(@trifecta_csv, :trifecta)

    summary = {
      "races" => actual_by_race.size,
      "exacta" => evaluate(actual_by_race, exacta_by_race, :exacta),
      "trifecta" => evaluate(actual_by_race, trifecta_by_race, :trifecta)
    }
    File.write(@out_path, JSON.pretty_generate(summary))

    warn "races=#{summary['races']}"
    warn "exacta_hit@1=#{format('%.6f', summary['exacta']['hit_at']['1'])}"
    warn "trifecta_hit@1=#{format('%.6f', summary['trifecta']['hit_at']['1'])}"
    warn "summary=#{@out_path}"
  end

  private

  def build_actual_by_race
    rows = CSV.read(@actual_csv, headers: true, encoding: "UTF-8").map(&:to_h)
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

  def evaluate(actual_by_race, pred_by_race, kind)
    races = actual_by_race.keys
    hit_at = {}
    races_with_pred = 0

    @ns.each do |n|
      hit = 0
      races.each do |race_id|
        pred = pred_by_race[race_id]
        next if pred.nil? || pred.empty?

        races_with_pred += 1 if n == @ns.first
        hit += 1 if pred.first(n).include?(actual_by_race[race_id][kind])
      end
      denom = races.size.zero? ? 1 : races.size
      hit_at[n.to_s] = hit.to_f / denom
    end

    {
      "races_total" => races.size,
      "races_with_pred" => races_with_pred,
      "hit_at" => hit_at
    }
  end
end

options = {
  actual_csv: File.join("data", "ml", "valid.csv"),
  exacta_csv: File.join("data", "ml", "exacta_pred.csv"),
  trifecta_csv: File.join("data", "ml", "trifecta_pred.csv"),
  out_path: File.join("data", "ml", "exotic_eval_summary.json"),
  ns: [1, 3, 5, 10, 20]
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: ruby scripts/evaluate_exotics.rb [options]"
  opts.on("--actual-csv PATH", "actual results CSV (default: data/ml/valid.csv)") { |v| options[:actual_csv] = v }
  opts.on("--exacta-csv PATH", "exacta prediction CSV (default: data/ml/exacta_pred.csv)") { |v| options[:exacta_csv] = v }
  opts.on("--trifecta-csv PATH", "trifecta prediction CSV (default: data/ml/trifecta_pred.csv)") { |v| options[:trifecta_csv] = v }
  opts.on("--out PATH", "output summary JSON path (default: data/ml/exotic_eval_summary.json)") { |v| options[:out_path] = v }
  opts.on("--ns LIST", "comma-separated hit@N list, e.g. 1,3,5,10,20") { |v| options[:ns] = v.split(",").map(&:to_i).select { |n| n > 0 } }
end
parser.parse!

raise "ns is empty" if options[:ns].empty?

ExoticEvaluator.new(
  actual_csv: options[:actual_csv],
  exacta_csv: options[:exacta_csv],
  trifecta_csv: options[:trifecta_csv],
  out_path: options[:out_path],
  ns: options[:ns]
).run
