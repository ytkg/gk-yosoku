#!/usr/bin/env ruby
# frozen_string_literal: true

require "csv"
require "fileutils"
require "json"
require "open3"
require "optparse"

class LightGBMTuner
  def initialize(train_csv:, valid_csv:, out_dir:, num_iterations:, early_stopping_round:, learning_rates:, num_leaves_list:, min_data_in_leaf_list:)
    @train_csv = train_csv
    @valid_csv = valid_csv
    @out_dir = out_dir
    @num_iterations = num_iterations
    @early_stopping_round = early_stopping_round
    @learning_rates = learning_rates
    @num_leaves_list = num_leaves_list
    @min_data_in_leaf_list = min_data_in_leaf_list
    FileUtils.mkdir_p(@out_dir)
  end

  def run
    results = []
    trial = 0

    @learning_rates.each do |lr|
      @num_leaves_list.each do |leaves|
        @min_data_in_leaf_list.each do |min_leaf|
          trial += 1
          trial_dir = File.join(@out_dir, format("trial_%03d", trial))
          FileUtils.mkdir_p(trial_dir)

          train!(trial_dir, lr, leaves, min_leaf)
          summary = evaluate!(trial_dir)

          row = {
            "trial" => trial,
            "learning_rate" => lr,
            "num_leaves" => leaves,
            "min_data_in_leaf" => min_leaf,
            "auc" => summary.fetch("auc"),
            "winner_hit_rate" => summary.fetch("winner_hit_rate"),
            "top3_exact_match_rate" => summary.fetch("top3_exact_match_rate"),
            "top3_recall_at3" => summary.fetch("top3_recall_at3")
          }
          results << row
          warn "trial=#{trial} auc=#{format('%.6f', row['auc'])} winner_hit_rate=#{format('%.6f', row['winner_hit_rate'])} lr=#{lr} leaves=#{leaves} min_leaf=#{min_leaf}"
        end
      end
    end

    ranked = results.sort_by { |r| [-r["auc"], -r["winner_hit_rate"]] }
    write_leaderboard(ranked)
    write_best(ranked.first)

    best = ranked.first
    warn "best_trial=#{best['trial']} auc=#{format('%.6f', best['auc'])} winner_hit_rate=#{format('%.6f', best['winner_hit_rate'])}"
  end

  private

  def train!(trial_dir, lr, leaves, min_leaf)
    cmd = [
      "ruby", "scripts/train_lightgbm.rb",
      "--train-csv", @train_csv,
      "--valid-csv", @valid_csv,
      "--out-dir", trial_dir,
      "--num-iterations", @num_iterations.to_s,
      "--learning-rate", lr.to_s,
      "--num-leaves", leaves.to_s,
      "--min-data-in-leaf", min_leaf.to_s,
      "--early-stopping-round", @early_stopping_round.to_s
    ]
    run_cmd!(cmd)
  end

  def evaluate!(trial_dir)
    cmd = [
      "ruby", "scripts/evaluate_lightgbm.rb",
      "--model", File.join(trial_dir, "model.txt"),
      "--valid-csv", @valid_csv,
      "--encoders", File.join(trial_dir, "encoders.json"),
      "--out-dir", trial_dir
    ]
    run_cmd!(cmd)

    summary_path = File.join(trial_dir, "eval_summary.json")
    JSON.parse(File.read(summary_path, encoding: "UTF-8"))
  end

  def write_leaderboard(rows)
    headers = %w[
      trial
      learning_rate
      num_leaves
      min_data_in_leaf
      auc
      winner_hit_rate
      top3_exact_match_rate
      top3_recall_at3
    ]
    path = File.join(@out_dir, "tune_leaderboard.csv")
    CSV.open(path, "w", write_headers: true, headers: headers) do |csv|
      rows.each { |r| csv << headers.map { |h| r[h] } }
    end
  end

  def write_best(best_row)
    File.write(File.join(@out_dir, "best_params.json"), JSON.pretty_generate(best_row))
  end

  def run_cmd!(cmd)
    out, err, status = Open3.capture3(*cmd)
    raise "command failed: #{cmd.join(' ')}\n#{err}\n#{out}" unless status.success?
  end
end

options = {
  train_csv: File.join("data", "ml", "train.csv"),
  valid_csv: File.join("data", "ml", "valid.csv"),
  out_dir: File.join("data", "ml", "tuning"),
  num_iterations: 400,
  early_stopping_round: 30,
  learning_rates: [0.03, 0.05],
  num_leaves_list: [31, 63],
  min_data_in_leaf_list: [20, 40, 80]
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: ruby scripts/tune_lightgbm.rb [options]"
  opts.on("--train-csv PATH", "train.csv path") { |v| options[:train_csv] = v }
  opts.on("--valid-csv PATH", "valid.csv path") { |v| options[:valid_csv] = v }
  opts.on("--out-dir DIR", "tuning output dir") { |v| options[:out_dir] = v }
  opts.on("--num-iterations N", Integer, "boosting rounds for each trial") { |v| options[:num_iterations] = v }
  opts.on("--early-stopping-round N", Integer, "early stopping rounds") { |v| options[:early_stopping_round] = v }
  opts.on("--learning-rates LIST", "comma separated float list (e.g. 0.03,0.05)") { |v| options[:learning_rates] = v.split(",").map(&:to_f) }
  opts.on("--num-leaves LIST", "comma separated int list (e.g. 31,63)") { |v| options[:num_leaves_list] = v.split(",").map(&:to_i) }
  opts.on("--min-data-in-leaf LIST", "comma separated int list (e.g. 20,40,80)") { |v| options[:min_data_in_leaf_list] = v.split(",").map(&:to_i) }
end
parser.parse!

LightGBMTuner.new(
  train_csv: options[:train_csv],
  valid_csv: options[:valid_csv],
  out_dir: options[:out_dir],
  num_iterations: options[:num_iterations],
  early_stopping_round: options[:early_stopping_round],
  learning_rates: options[:learning_rates],
  num_leaves_list: options[:num_leaves_list],
  min_data_in_leaf_list: options[:min_data_in_leaf_list]
).run
