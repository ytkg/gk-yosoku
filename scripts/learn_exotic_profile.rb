#!/usr/bin/env ruby
# frozen_string_literal: true

require "csv"
require "fileutils"
require "json"
require "optparse"
require "yaml"
require_relative "lib/duckdb_runner"
require_relative "lib/exotic_scoring"

class ExoticProfileLearner
  def initialize(train_top3_csv:, train_top1_csv:, train_actual_csv:, train_actual_parquet:, valid_top3_csv:, valid_top1_csv:, valid_actual_csv:, valid_actual_parquet:, db_path:, out_path:, objective_n:, exacta_weight:, trifecta_weight:, temp_grid:, exp_grid:, exacta_second_win_exp_grid:, max_trials:, random_seed:, config_path:, cli_overrides:)
    @train_top3_csv = train_top3_csv
    @train_top1_csv = train_top1_csv
    @train_actual_csv = train_actual_csv
    @train_actual_parquet = train_actual_parquet
    @valid_top3_csv = valid_top3_csv
    @valid_top1_csv = valid_top1_csv
    @valid_actual_csv = valid_actual_csv
    @valid_actual_parquet = valid_actual_parquet
    @db_path = db_path
    @out_path = out_path
    @objective_n = objective_n
    @exacta_weight = exacta_weight
    @trifecta_weight = trifecta_weight
    @temp_grid = temp_grid
    @exp_grid = exp_grid
    @exacta_second_win_exp_grid = exacta_second_win_exp_grid
    @max_trials = max_trials.to_i
    @random_seed = random_seed.to_i
    @config_path = config_path
    @cli_overrides = cli_overrides
  end

  def run
    train_races = build_races(@train_top3_csv, @train_top1_csv, resolved_actual_csv(:train))
    valid_races = build_races(@valid_top3_csv, @valid_top1_csv, resolved_actual_csv(:valid))
    raise "train races is empty" if train_races.empty?
    raise "valid races is empty" if valid_races.empty?

    best = nil
    total_combinations = parameter_space
    selected_combinations = select_combinations(total_combinations)

    selected_combinations.each_with_index do |combo, idx|
      trial = idx + 1
      params = build_params(
        temp: combo.fetch(:temp),
        exacta_win_exp: combo.fetch(:exacta_win_exp),
        exacta_second_exp: combo.fetch(:exacta_second_exp),
        exacta_second_win_exp: combo.fetch(:exacta_second_win_exp),
        trifecta_second_exp: combo.fetch(:trifecta_second_exp),
        trifecta_third_exp: combo.fetch(:trifecta_third_exp)
      )
      train_metric = evaluate(
        train_races,
        params,
        ns: [@objective_n.to_s],
        compute_exacta: @exacta_weight.positive?,
        compute_trifecta: @trifecta_weight.positive?
      )
      ex = train_metric.dig("exacta", "hit_at", @objective_n.to_s) || 0.0
      tri = train_metric.dig("trifecta", "hit_at", @objective_n.to_s) || 0.0
      objective = (@exacta_weight * ex) + (@trifecta_weight * tri)
      candidate = {
        "trial" => trial,
        "objective" => objective,
        "params" => params,
        "combo" => combo.transform_keys(&:to_s),
        "train_objective_hit_at" => {
          "exacta" => ex,
          "trifecta" => tri
        }
      }
      best = better_of(best, candidate)
    end

    ns = %w[1 3 5 10 20]
    train_eval = evaluate(train_races, best.fetch("params"), ns: ns)
    valid_eval = evaluate(valid_races, best.fetch("params"), ns: ns)
    out = {
      "version" => 1,
      "optimized_for" => "hit@#{@objective_n}",
      "search_space" => {
        "temperature_grid" => @temp_grid,
        "exp_grid" => @exp_grid,
        "exacta_second_win_exp_grid" => @exacta_second_win_exp_grid,
        "max_trials" => @max_trials,
        "random_seed" => @random_seed,
        "total_combinations" => total_combinations.size,
        "searched_combinations" => selected_combinations.size,
        "exacta_weight" => @exacta_weight,
        "trifecta_weight" => @trifecta_weight
      },
      "config" => @config_path.nil? ? nil : { "path" => @config_path, "cli_overrides" => @cli_overrides },
      "best" => best,
      "train_eval" => train_eval,
      "valid_eval" => valid_eval,
      "params" => best.fetch("params")
    }
    FileUtils.mkdir_p(File.dirname(@out_path))
    File.write(@out_path, JSON.pretty_generate(out))

    warn "trials=#{selected_combinations.size}"
    warn "total_combinations=#{total_combinations.size}"
    warn format("best_objective=%.6f", best.fetch("objective"))
    warn format("train_exacta_hit@%d=%.6f", @objective_n, train_eval.dig("exacta", "hit_at", @objective_n.to_s))
    warn format("train_trifecta_hit@%d=%.6f", @objective_n, train_eval.dig("trifecta", "hit_at", @objective_n.to_s))
    warn format("valid_exacta_hit@%d=%.6f", @objective_n, valid_eval.dig("exacta", "hit_at", @objective_n.to_s))
    warn format("valid_trifecta_hit@%d=%.6f", @objective_n, valid_eval.dig("trifecta", "hit_at", @objective_n.to_s))
    warn "profile=#{@out_path}"
  end

  private

  def resolved_actual_csv(split)
    parquet_path, csv_path =
      if split == :train
        [@train_actual_parquet, @train_actual_csv]
      else
        [@valid_actual_parquet, @valid_actual_csv]
      end
    return csv_path if parquet_path.nil? || parquet_path.empty?

    out_csv = File.join(File.dirname(@out_path), "#{split}_actual_from_parquet.csv")
    warn "#{split}_actual input mode=parquet"
    materialize_parquet_to_csv(parquet_path, out_csv)
  end

  def materialize_parquet_to_csv(parquet_path, out_csv_path)
    GK::DuckDBRunner.ensure_duckdb!(message: "duckdb command not found for parquet input")
    sql = <<~SQL
      COPY (
        SELECT *
        FROM read_parquet(#{GK::DuckDBRunner.sql_quote(parquet_path)})
      )
      TO #{GK::DuckDBRunner.sql_quote(out_csv_path)}
      (HEADER, DELIMITER ',');
    SQL
    GK::DuckDBRunner.run_sql!(db_path: @db_path, sql: sql)
    out_csv_path
  end

  def better_of(best, candidate)
    return candidate if best.nil?
    return candidate if candidate.fetch("objective") > best.fetch("objective")
    return best if candidate.fetch("objective") < best.fetch("objective")

    c_ex = candidate.dig("train_objective_hit_at", "exacta")
    b_ex = best.dig("train_objective_hit_at", "exacta")
    c_tri = candidate.dig("train_objective_hit_at", "trifecta")
    b_tri = best.dig("train_objective_hit_at", "trifecta")

    if @exacta_weight >= @trifecta_weight
      return candidate if c_ex > b_ex
      return best if c_ex < b_ex
      return candidate if c_tri > b_tri
      return best if c_tri < b_tri
    else
      return candidate if c_tri > b_tri
      return best if c_tri < b_tri
      return candidate if c_ex > b_ex
      return best if c_ex < b_ex
    end

    best
  end

  def parameter_space
    exacta_win_grid = @exacta_weight.positive? ? @exp_grid : [GK::ExoticScoring.default_params.dig("exacta", "win_exp")]
    exacta_second_grid = @exacta_weight.positive? ? @exp_grid : [GK::ExoticScoring.default_params.dig("exacta", "second_exp")]
    exacta_second_win_grid = @exacta_weight.positive? ? @exacta_second_win_exp_grid : [GK::ExoticScoring.default_params.dig("exacta", "second_win_exp")]
    trifecta_second_grid = @trifecta_weight.positive? ? @exp_grid : [GK::ExoticScoring.default_params.dig("trifecta", "second_exp")]
    trifecta_third_grid = @trifecta_weight.positive? ? @exp_grid : [GK::ExoticScoring.default_params.dig("trifecta", "third_exp")]

    combos = []
    @temp_grid.each do |temp|
      exacta_win_grid.each do |exacta_win_exp|
        exacta_second_grid.each do |exacta_second_exp|
          exacta_second_win_grid.each do |exacta_second_win_exp|
            trifecta_second_grid.each do |trifecta_second_exp|
              trifecta_third_grid.each do |trifecta_third_exp|
                combos << {
                  temp: temp,
                  exacta_win_exp: exacta_win_exp,
                  exacta_second_exp: exacta_second_exp,
                  exacta_second_win_exp: exacta_second_win_exp,
                  trifecta_second_exp: trifecta_second_exp,
                  trifecta_third_exp: trifecta_third_exp
                }
              end
            end
          end
        end
      end
    end
    combos
  end

  def select_combinations(all)
    return all if @max_trials <= 0 || @max_trials >= all.size

    rnd = Random.new(@random_seed)
    all.shuffle(random: rnd).first(@max_trials)
  end

  def build_params(temp:, exacta_win_exp:, exacta_second_exp:, exacta_second_win_exp:, trifecta_second_exp:, trifecta_third_exp:)
    GK::ExoticScoring.merge_params(
      GK::ExoticScoring.default_params,
      {
        "win_temperature" => temp,
        "exacta" => {
          "win_exp" => exacta_win_exp,
          "second_exp" => exacta_second_exp,
          "second_win_exp" => exacta_second_win_exp
        },
        "trifecta" => {
          "win_exp" => exacta_win_exp,
          "second_exp" => trifecta_second_exp,
          "third_exp" => trifecta_third_exp
        }
      }
    )
  end

  def build_races(top3_csv, top1_csv, actual_csv)
    top3_rows = CSV.read(top3_csv, headers: true, encoding: "UTF-8").map(&:to_h)
    top1_rows = CSV.read(top1_csv, headers: true, encoding: "UTF-8").map(&:to_h)
    actual_by_race = build_actual_by_race(actual_csv)
    top3_grouped = top3_rows.group_by { |r| r["race_id"] }
    top1_index = top1_rows.to_h { |r| [[r["race_id"], r["car_number"]], r["score"].to_f] }

    top3_grouped.each_with_object([]) do |(race_id, rows), races|
      actual = actual_by_race[race_id]
      next if actual.nil?

      cars = rows.map do |r|
        key = [r["race_id"], r["car_number"]]
        next unless top1_index.key?(key)

        {
          "car_number" => r["car_number"].to_i,
          "top3_score" => GK::ExoticScoring.clamp01(r["score"].to_f),
          "win_score" => top1_index[key]
        }
      end.compact
      next if cars.size < 3

      races << {
        "race_id" => race_id,
        "cars" => cars,
        "actual_exacta" => actual.fetch("exacta"),
        "actual_trifecta" => actual.fetch("trifecta")
      }
    end
  end

  def build_actual_by_race(path)
    rows = CSV.read(path, headers: true, encoding: "UTF-8").map(&:to_h)
    rows.group_by { |r| r["race_id"] }.each_with_object({}) do |(race_id, rs), h|
      normal_rows = rs.select { |r| r["rank"].to_s.match?(/\A[1-7]\z/) }
      next unless normal_rows.size >= 3

      sorted = normal_rows.sort_by { |r| r["rank"].to_i }
      h[race_id] = {
        "exacta" => [sorted[0]["car_number"].to_i, sorted[1]["car_number"].to_i],
        "trifecta" => [sorted[0]["car_number"].to_i, sorted[1]["car_number"].to_i, sorted[2]["car_number"].to_i]
      }
    end
  end

  def evaluate(races, params, ns:, compute_exacta: true, compute_trifecta: true)
    exacta_hit = compute_exacta ? ns.to_h { |n| [n, 0] } : nil
    trifecta_hit = compute_trifecta ? ns.to_h { |n| [n, 0] } : nil
    races.each do |race|
      p_win = GK::ExoticScoring.win_probs(
        race.fetch("cars"),
        params.fetch("win_temperature"),
        car_key: "car_number",
        win_key: "win_score"
      )
      p_top3 = race.fetch("cars").to_h { |c| [c.fetch("car_number"), c.fetch("top3_score")] }

      exacta = []
      trifecta = []
      race.fetch("cars").each do |i|
        race.fetch("cars").each do |j|
          next if i["car_number"] == j["car_number"]

          if compute_exacta
            s = GK::ExoticScoring.score_exacta(
              p_win: p_win,
              p_top3: p_top3,
              first_car: i["car_number"],
              second_car: j["car_number"],
              params: params
            )
            exacta << [[i["car_number"], j["car_number"]], GK::ExoticScoring.format_score(s).to_f]
          end

          next unless compute_trifecta

          race.fetch("cars").each do |k|
            next if k["car_number"] == i["car_number"] || k["car_number"] == j["car_number"]

            s3 = GK::ExoticScoring.score_trifecta(
              p_win: p_win,
              p_top3: p_top3,
              first_car: i["car_number"],
              second_car: j["car_number"],
              third_car: k["car_number"],
              params: params
            )
            trifecta << [[i["car_number"], j["car_number"], k["car_number"]], GK::ExoticScoring.format_score(s3).to_f]
          end
        end
      end

      exacta_sorted = compute_exacta ? exacta.sort_by { |x| [-x[1], x[0].join("-")] } : nil
      trifecta_sorted = compute_trifecta ? trifecta.sort_by { |x| [-x[1], x[0].join("-")] } : nil
      ns.each do |n|
        if compute_exacta
          exacta_hit[n] += 1 if exacta_sorted.first(n.to_i).any? { |x| x[0] == race.fetch("actual_exacta") }
        end
        if compute_trifecta
          trifecta_hit[n] += 1 if trifecta_sorted.first(n.to_i).any? { |x| x[0] == race.fetch("actual_trifecta") }
        end
      end
    end

    out = { "races" => races.size }
    out["exacta"] = { "hit_at" => exacta_hit.transform_values { |v| v.to_f / races.size } } if compute_exacta
    out["trifecta"] = { "hit_at" => trifecta_hit.transform_values { |v| v.to_f / races.size } } if compute_trifecta
    out
  end
end

options = {
  train_top3_csv: File.join("data", "ml_profile", "top3_train", "valid_pred.csv"),
  train_top1_csv: File.join("data", "ml_profile", "top1_train", "valid_pred.csv"),
  train_actual_csv: File.join("data", "ml", "train.csv"),
  train_actual_parquet: nil,
  valid_top3_csv: File.join("data", "ml_profile", "top3_valid", "valid_pred.csv"),
  valid_top1_csv: File.join("data", "ml_profile", "top1_valid", "valid_pred.csv"),
  valid_actual_csv: File.join("data", "ml", "valid.csv"),
  valid_actual_parquet: nil,
  db_path: File.join("data", "duckdb", "gk_yosoku.duckdb"),
  out_path: File.join("data", "ml", "exotic_profile_hit5.json"),
  objective_n: 5,
  exacta_weight: 1.0,
  trifecta_weight: 1.0,
  temp_grid: [0.15, 0.25],
  exp_grid: [0.8, 1.0],
  exacta_second_win_exp_grid: [0.0],
  max_trials: 0,
  random_seed: 42,
  config_path: nil,
  cli_overrides: []
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: ruby scripts/learn_exotic_profile.rb [options]"
  opts.on("--config PATH", "YAML config path (CLI options override config)") { |v| options[:config_path] = v }
  opts.on("--train-top3-csv PATH", "train top3 prediction csv") { |v| options[:train_top3_csv] = v }
  opts.on("--train-top1-csv PATH", "train top1 prediction csv") { |v| options[:train_top1_csv] = v }
  opts.on("--train-actual-csv PATH", "train actual csv (compatibility mode)") { |v| options[:train_actual_csv] = v }
  opts.on("--train-actual-parquet PATH", "train actual parquet (recommended)") { |v| options[:train_actual_parquet] = v }
  opts.on("--valid-top3-csv PATH", "valid top3 prediction csv") { |v| options[:valid_top3_csv] = v }
  opts.on("--valid-top1-csv PATH", "valid top1 prediction csv") { |v| options[:valid_top1_csv] = v }
  opts.on("--valid-actual-csv PATH", "valid actual csv (compatibility mode)") { |v| options[:valid_actual_csv] = v }
  opts.on("--valid-actual-parquet PATH", "valid actual parquet (recommended)") { |v| options[:valid_actual_parquet] = v }
  opts.on("--db-path PATH", "DuckDB DB path for parquet input") { |v| options[:db_path] = v }
  opts.on("--out PATH", "output profile json path") { |v| options[:out_path] = v }
  opts.on("--objective-n N", Integer, "optimize hit@N (default: 5)") { |v| options[:objective_n] = v }
  opts.on("--exacta-weight X", Float, "objective weight for exacta hit@N (default: 1.0)") { |v| options[:exacta_weight] = v }
  opts.on("--trifecta-weight X", Float, "objective weight for trifecta hit@N (default: 1.0)") { |v| options[:trifecta_weight] = v }
  opts.on("--temp-grid LIST", "comma-separated grid, e.g. 0.1,0.15,0.2") { |v| options[:temp_grid] = v.split(",").map(&:to_f).select { |x| x.positive? } }
  opts.on("--exp-grid LIST", "comma-separated exponent grid, e.g. 0.8,1.0,1.2") { |v| options[:exp_grid] = v.split(",").map(&:to_f).select { |x| x.positive? } }
  opts.on("--exacta-second-win-exp-grid LIST", "comma-separated exponent grid for exacta second win prob, e.g. 0.0,0.2,0.5") { |v| options[:exacta_second_win_exp_grid] = v.split(",").map(&:to_f).select { |x| x >= 0.0 } }
  opts.on("--max-trials N", Integer, "randomly sample at most N parameter combinations (0 means exhaustive)") { |v| options[:max_trials] = v }
  opts.on("--random-seed N", Integer, "random seed for --max-trials sampling (default: 42)") { |v| options[:random_seed] = v }
end

raw_args = ARGV.dup

pre_config_path = nil
ARGV.each_with_index do |arg, idx|
  if arg == "--config"
    pre_config_path = ARGV[idx + 1]
    next
  end
  pre_config_path = arg.split("=", 2)[1] if arg.start_with?("--config=")
end

if pre_config_path
  config = YAML.safe_load(File.read(pre_config_path, encoding: "UTF-8"), permitted_classes: [], aliases: false) || {}
  raise "config must be a mapping" unless config.is_a?(Hash)

  config.each do |key, value|
    sym = key.to_s.tr("-", "_").to_sym
    next unless options.key?(sym)
    next if sym == :config_path

    options[sym] = value
  end
  options[:config_path] = pre_config_path
end

parser.parse!

cli_override_keys = []
i = 0
while i < raw_args.size
  token = raw_args[i]
  if token.start_with?("--")
    if token.include?("=")
      key = token.split("=", 2)[0]
      cli_override_keys << key
    else
      cli_override_keys << token
      i += 1 if (i + 1) < raw_args.size && !raw_args[i + 1].start_with?("--")
    end
  end
  i += 1
end
options[:cli_overrides] = cli_override_keys
  .map { |k| k.sub(/\A--/, "").tr("-", "_") }
  .reject { |k| k == "config" }
  .uniq

options[:temp_grid] = options[:temp_grid].split(",").map(&:to_f).select { |x| x.positive? } if options[:temp_grid].is_a?(String)
options[:exp_grid] = options[:exp_grid].split(",").map(&:to_f).select { |x| x.positive? } if options[:exp_grid].is_a?(String)
if options[:exacta_second_win_exp_grid].is_a?(String)
  options[:exacta_second_win_exp_grid] = options[:exacta_second_win_exp_grid].split(",").map(&:to_f).select { |x| x >= 0.0 }
end

begin
  options[:objective_n] = Integer(options[:objective_n])
rescue StandardError
  raise "objective_n must be integer"
end
begin
  options[:max_trials] = Integer(options[:max_trials])
rescue StandardError
  raise "max_trials must be integer"
end
begin
  options[:random_seed] = Integer(options[:random_seed])
rescue StandardError
  raise "random_seed must be integer"
end
begin
  options[:exacta_weight] = Float(options[:exacta_weight])
  options[:trifecta_weight] = Float(options[:trifecta_weight])
rescue StandardError
  raise "exacta_weight and trifecta_weight must be float"
end

raise "temp-grid is empty" if !options[:temp_grid].is_a?(Array) || options[:temp_grid].empty?
raise "exp-grid is empty" if !options[:exp_grid].is_a?(Array) || options[:exp_grid].empty?
if !options[:exacta_second_win_exp_grid].is_a?(Array) || options[:exacta_second_win_exp_grid].empty?
  raise "exacta-second-win-exp-grid is empty"
end
raise "temp-grid must contain only positive numbers" unless options[:temp_grid].all? { |x| x.to_f.positive? }
raise "exp-grid must contain only positive numbers" unless options[:exp_grid].all? { |x| x.to_f.positive? }
unless options[:exacta_second_win_exp_grid].all? { |x| x.to_f >= 0.0 }
  raise "exacta-second-win-exp-grid must contain only non-negative numbers"
end
raise "objective_n must be >= 1" if options[:objective_n] < 1
raise "max_trials must be >= 0" if options[:max_trials] < 0
if options[:exacta_weight].negative? || options[:trifecta_weight].negative?
  raise "exacta_weight and trifecta_weight must be >= 0"
end
if options[:exacta_weight].zero? && options[:trifecta_weight].zero?
  raise "exacta_weight and trifecta_weight cannot both be 0"
end

ExoticProfileLearner.new(
  train_top3_csv: options[:train_top3_csv],
  train_top1_csv: options[:train_top1_csv],
  train_actual_csv: options[:train_actual_csv],
  train_actual_parquet: options[:train_actual_parquet],
  valid_top3_csv: options[:valid_top3_csv],
  valid_top1_csv: options[:valid_top1_csv],
  valid_actual_csv: options[:valid_actual_csv],
  valid_actual_parquet: options[:valid_actual_parquet],
  db_path: options[:db_path],
  out_path: options[:out_path],
  objective_n: options[:objective_n],
  exacta_weight: options[:exacta_weight],
  trifecta_weight: options[:trifecta_weight],
  temp_grid: options[:temp_grid],
  exp_grid: options[:exp_grid],
  exacta_second_win_exp_grid: options[:exacta_second_win_exp_grid],
  max_trials: options[:max_trials],
  random_seed: options[:random_seed],
  config_path: options[:config_path],
  cli_overrides: options[:cli_overrides]
).run
