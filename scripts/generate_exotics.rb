#!/usr/bin/env ruby
# frozen_string_literal: true

require "csv"
require "fileutils"
require "optparse"
require_relative "lib/exotic_scoring"

class ExoticGenerator
  def initialize(in_csv:, win_csv:, out_dir:, exacta_top:, trifecta_top:, exotic_params:)
    @in_csv = in_csv
    @win_csv = win_csv
    @out_dir = out_dir
    @exacta_top = exacta_top
    @trifecta_top = trifecta_top
    @exotic_params = exotic_params
    @win_temperature = @exotic_params.fetch("win_temperature")
    FileUtils.mkdir_p(@out_dir)
  end

  def run
    top3_rows = CSV.read(@in_csv, headers: true, encoding: "UTF-8").map(&:to_h)
    raise "input is empty: #{@in_csv}" if top3_rows.empty?
    win_rows = CSV.read(@win_csv, headers: true, encoding: "UTF-8").map(&:to_h)
    raise "input is empty: #{@win_csv}" if win_rows.empty?

    top3_grouped = top3_rows.group_by { |r| r["race_id"] }
    win_index = win_rows.to_h { |r| [[r["race_id"], r["car_number"]], r["score"].to_f] }
    exacta_rows = []
    trifecta_rows = []

    top3_grouped.each do |race_id, rs|
      race_meta = rs.first
      cars = rs.map do |r|
        key = [r["race_id"], r["car_number"]]
        next unless win_index.key?(key)

        {
          "car_number" => r["car_number"].to_i,
          "player_name" => r["player_name"],
          "top3_score" => r["score"].to_f,
          "win_score" => win_index[key]
        }
      end.compact
      next if cars.size < 3

      p_win = win_probs(cars)
      p_top3 = cars.to_h { |c| [c["car_number"], GK::ExoticScoring.clamp01(c["top3_score"])] }

      exacta = []
      cars.each do |i|
        cars.each do |j|
          next if i["car_number"] == j["car_number"]

          s = GK::ExoticScoring.score_exacta(
            p_win: p_win,
            p_top3: p_top3,
            first_car: i["car_number"],
            second_car: j["car_number"],
            params: @exotic_params
          )
          exacta << {
            "race_id" => race_id,
            "race_date" => race_meta["race_date"],
            "venue" => race_meta["venue"],
            "race_number" => race_meta["race_number"],
            "first_car_number" => i["car_number"].to_s,
            "first_player_name" => i["player_name"],
            "second_car_number" => j["car_number"].to_s,
            "second_player_name" => j["player_name"],
            "score" => s
          }
        end
      end
      exacta_rows.concat(exacta.sort_by { |r| -r["score"] }.first(@exacta_top))

      trifecta = []
      cars.each do |i|
        cars.each do |j|
          next if i["car_number"] == j["car_number"]

          cars.each do |k|
            next if k["car_number"] == i["car_number"] || k["car_number"] == j["car_number"]

            s = GK::ExoticScoring.score_trifecta(
              p_win: p_win,
              p_top3: p_top3,
              first_car: i["car_number"],
              second_car: j["car_number"],
              third_car: k["car_number"],
              params: @exotic_params
            )
            trifecta << {
              "race_id" => race_id,
              "race_date" => race_meta["race_date"],
              "venue" => race_meta["venue"],
              "race_number" => race_meta["race_number"],
              "first_car_number" => i["car_number"].to_s,
              "first_player_name" => i["player_name"],
              "second_car_number" => j["car_number"].to_s,
              "second_player_name" => j["player_name"],
              "third_car_number" => k["car_number"].to_s,
              "third_player_name" => k["player_name"],
              "score" => s
            }
          end
        end
      end
      trifecta_rows.concat(trifecta.sort_by { |r| -r["score"] }.first(@trifecta_top))
    end

    write_exacta(exacta_rows)
    write_trifecta(trifecta_rows)
    warn "params=#{@exotic_params}"
    warn "races=#{top3_grouped.size} exacta_rows=#{exacta_rows.size} trifecta_rows=#{trifecta_rows.size}"
  end

  private

  def win_probs(cars)
    exps = cars.to_h do |c|
      z = c["win_score"] / @win_temperature
      [c["car_number"], Math.exp(z)]
    end
    sum = exps.values.sum
    exps.transform_values { |v| v / sum }
  end

  def write_exacta(rows)
    headers = %w[
      race_id race_date venue race_number
      first_car_number first_player_name
      second_car_number second_player_name
      score
    ]
    path = File.join(@out_dir, "exacta_pred.csv")
    CSV.open(path, "w", write_headers: true, headers: headers) do |csv|
      rows.each do |r|
        csv << headers.map { |h| h == "score" ? format_score(r[h]) : r[h] }
      end
    end
  end

  def write_trifecta(rows)
    headers = %w[
      race_id race_date venue race_number
      first_car_number first_player_name
      second_car_number second_player_name
      third_car_number third_player_name
      score
    ]
    path = File.join(@out_dir, "trifecta_pred.csv")
    CSV.open(path, "w", write_headers: true, headers: headers) do |csv|
      rows.each do |r|
        csv << headers.map { |h| h == "score" ? format_score(r[h]) : r[h] }
      end
    end
  end

  def format_score(value)
    GK::ExoticScoring.format_score(value)
  end
end

options = {
  in_csv: File.join("data", "ml", "valid_pred.csv"),
  win_csv: File.join("data", "ml", "valid_pred.csv"),
  out_dir: File.join("data", "ml"),
  exacta_top: 10,
  trifecta_top: 20,
  win_temperature: nil,
  profile: nil,
  exacta_win_exp: nil,
  exacta_second_exp: nil,
  trifecta_win_exp: nil,
  trifecta_second_exp: nil,
  trifecta_third_exp: nil
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: ruby scripts/generate_exotics.rb [options]"
  opts.on("--in-csv PATH", "input top3 prediction csv (default: data/ml/valid_pred.csv)") { |v| options[:in_csv] = v }
  opts.on("--win-csv PATH", "input top1 prediction csv (default: same as --in-csv)") { |v| options[:win_csv] = v }
  opts.on("--out-dir DIR", "output dir (default: data/ml)") { |v| options[:out_dir] = v }
  opts.on("--exacta-top N", Integer, "top N exacta per race (default: 10)") { |v| options[:exacta_top] = v }
  opts.on("--trifecta-top N", Integer, "top N trifecta per race (default: 20)") { |v| options[:trifecta_top] = v }
  opts.on("--win-temperature X", Float, "softmax temperature for win proxy (default: profile or 0.2)") { |v| options[:win_temperature] = v }
  opts.on("--profile PATH", "exotic score profile json path") { |v| options[:profile] = v }
  opts.on("--exacta-win-exp X", Float, "exacta: exponent for first-car win prob") { |v| options[:exacta_win_exp] = v }
  opts.on("--exacta-second-exp X", Float, "exacta: exponent for second-car top3 prob") { |v| options[:exacta_second_exp] = v }
  opts.on("--exacta-second-win-exp X", Float, "exacta: exponent for second-car win prob") { |v| options[:exacta_second_win_exp] = v }
  opts.on("--trifecta-win-exp X", Float, "trifecta: exponent for first-car win prob") { |v| options[:trifecta_win_exp] = v }
  opts.on("--trifecta-second-exp X", Float, "trifecta: exponent for second-car top3 prob") { |v| options[:trifecta_second_exp] = v }
  opts.on("--trifecta-third-exp X", Float, "trifecta: exponent for third-car top3 prob") { |v| options[:trifecta_third_exp] = v }
end
parser.parse!

base = GK::ExoticScoring.default_params
if options[:profile]
  base = GK::ExoticScoring.merge_params(base, GK::ExoticScoring.load_profile(options[:profile]))
end
overrides = {}
overrides["win_temperature"] = options[:win_temperature] unless options[:win_temperature].nil?
unless options[:exacta_win_exp].nil?
  overrides["exacta"] ||= {}
  overrides["exacta"]["win_exp"] = options[:exacta_win_exp]
end
unless options[:exacta_second_exp].nil?
  overrides["exacta"] ||= {}
  overrides["exacta"]["second_exp"] = options[:exacta_second_exp]
end
unless options[:exacta_second_win_exp].nil?
  overrides["exacta"] ||= {}
  overrides["exacta"]["second_win_exp"] = options[:exacta_second_win_exp]
end
unless options[:trifecta_win_exp].nil?
  overrides["trifecta"] ||= {}
  overrides["trifecta"]["win_exp"] = options[:trifecta_win_exp]
end
unless options[:trifecta_second_exp].nil?
  overrides["trifecta"] ||= {}
  overrides["trifecta"]["second_exp"] = options[:trifecta_second_exp]
end
unless options[:trifecta_third_exp].nil?
  overrides["trifecta"] ||= {}
  overrides["trifecta"]["third_exp"] = options[:trifecta_third_exp]
end
params = GK::ExoticScoring.merge_params(base, overrides)

ExoticGenerator.new(
  in_csv: options[:in_csv],
  win_csv: options[:win_csv],
  out_dir: options[:out_dir],
  exacta_top: options[:exacta_top],
  trifecta_top: options[:trifecta_top],
  exotic_params: params
).run
