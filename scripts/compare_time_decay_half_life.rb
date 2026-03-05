#!/usr/bin/env ruby
# frozen_string_literal: true

require "csv"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "rbconfig"

class HalfLifeComparer
  def initialize(from_date:, to_date:, train_days:, valid_days:, step_days:, half_lives:, min_sample_weight:, lake_dir:, db_path:, feature_set_version:, target_col:, out_dir:, cv_script:)
    @from_date = from_date
    @to_date = to_date
    @train_days = train_days
    @valid_days = valid_days
    @step_days = step_days
    @half_lives = half_lives
    @min_sample_weight = min_sample_weight
    @lake_dir = lake_dir
    @db_path = db_path
    @feature_set_version = feature_set_version
    @target_col = target_col
    @out_dir = out_dir
    @cv_script = cv_script
  end

  def run
    FileUtils.mkdir_p(@out_dir)
    rows = @half_lives.map do |half_life|
      cv_dir = File.join(@out_dir, "half_life_#{format('%.1f', half_life).tr('.', '_')}")
      run_cv!(half_life, cv_dir)
      summary = JSON.parse(File.read(File.join(cv_dir, "cv_summary.json"), encoding: "UTF-8"))
      metric_auc = summary.dig("metrics", "auc", "mean")
      metric_winner = summary.dig("metrics", "winner_hit_rate", "mean")
      metric_top3_exact = summary.dig("metrics", "top3_exact_match_rate", "mean")
      metric_top3_recall = summary.dig("metrics", "top3_recall_at3", "mean")
      {
        "half_life_days" => half_life,
        "target_col" => @target_col,
        "folds" => summary["folds"],
        "auc_mean" => metric_auc,
        "winner_hit_rate_mean" => metric_winner,
        "top3_exact_match_rate_mean" => metric_top3_exact,
        "top3_recall_at3_mean" => metric_top3_recall,
        "cv_summary_path" => File.join(cv_dir, "cv_summary.json")
      }
    end

    ranked = rows.sort_by { |r| [-r.fetch("winner_hit_rate_mean", 0.0), -r.fetch("auc_mean", 0.0)] }
    write_outputs(ranked)
  end

  private

  def run_cv!(half_life, cv_dir)
    cmd = [
      RbConfig.ruby, @cv_script,
      "--from-date", @from_date,
      "--to-date", @to_date,
      "--train-days", @train_days.to_s,
      "--valid-days", @valid_days.to_s,
      "--step-days", @step_days.to_s,
      "--lake-dir", @lake_dir,
      "--db-path", @db_path,
      "--feature-set-version", @feature_set_version,
      "--out-dir", cv_dir,
      "--target-col", @target_col,
      "--weight-mode", "time_decay",
      "--decay-half-life-days", half_life.to_s,
      "--min-sample-weight", @min_sample_weight.to_s
    ]
    out, err, status = Open3.capture3(*cmd)
    raise "cv failed (half_life=#{half_life}): #{err}\n#{out}" unless status.success?
  end

  def write_outputs(rows)
    leaderboard_csv = File.join(@out_dir, "half_life_leaderboard.csv")
    headers = %w[
      half_life_days target_col folds auc_mean winner_hit_rate_mean top3_exact_match_rate_mean top3_recall_at3_mean cv_summary_path
    ]
    CSV.open(leaderboard_csv, "w", write_headers: true, headers: headers) do |csv|
      rows.each { |row| csv << headers.map { |h| row[h] } }
    end

    best = rows.first
    summary = {
      "target_col" => @target_col,
      "candidates" => rows.size,
      "options" => {
        "from_date" => @from_date,
        "to_date" => @to_date,
        "train_days" => @train_days,
        "valid_days" => @valid_days,
        "step_days" => @step_days,
        "half_lives" => @half_lives,
        "min_sample_weight" => @min_sample_weight,
        "lake_dir" => @lake_dir,
        "db_path" => @db_path,
        "feature_set_version" => @feature_set_version
      },
      "best" => best,
      "rows" => rows
    }
    summary_json = File.join(@out_dir, "half_life_summary.json")
    File.write(summary_json, JSON.pretty_generate(summary))

    warn "leaderboard=#{leaderboard_csv}"
    warn "summary=#{summary_json}"
    warn "best_half_life_days=#{best['half_life_days']}"
  end
end

options = {
  from_date: nil,
  to_date: nil,
  train_days: 180,
  valid_days: 28,
  step_days: 28,
  half_lives: [60.0, 90.0, 120.0, 180.0],
  min_sample_weight: 0.2,
  lake_dir: File.join("data", "lake"),
  db_path: File.join("data", "duckdb", "gk_yosoku.duckdb"),
  feature_set_version: "v1",
  target_col: "top3",
  out_dir: File.join("data", "ml_cv_half_life"),
  cv_script: File.join("scripts", "run_timeseries_cv.rb")
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: ruby scripts/compare_time_decay_half_life.rb --from-date YYYY-MM-DD --to-date YYYY-MM-DD [options]"
  opts.on("--from-date DATE", "最小日付 (YYYY-MM-DD)") { |v| options[:from_date] = v }
  opts.on("--to-date DATE", "最大日付 (YYYY-MM-DD)") { |v| options[:to_date] = v }
  opts.on("--train-days N", Integer, "学習窓の日数 (default: 180)") { |v| options[:train_days] = v }
  opts.on("--valid-days N", Integer, "検証窓の日数 (default: 28)") { |v| options[:valid_days] = v }
  opts.on("--step-days N", Integer, "fold間のステップ日数 (default: 28)") { |v| options[:step_days] = v }
  opts.on("--half-lives LIST", "半減期候補（例: 60,90,120,180）") { |v| options[:half_lives] = v.split(",").map(&:to_f).select(&:positive?) }
  opts.on("--min-sample-weight X", Float, "time_decay最小重み (default: 0.2)") { |v| options[:min_sample_weight] = v }
  opts.on("--lake-dir DIR", "features Parquet入力ルート") { |v| options[:lake_dir] = v }
  opts.on("--db-path PATH", "DuckDB DBファイル") { |v| options[:db_path] = v }
  opts.on("--feature-set-version NAME", "feature set version (default: v1)") { |v| options[:feature_set_version] = v }
  opts.on("--target-col NAME", "top3 or top1 (default: top3)") { |v| options[:target_col] = v }
  opts.on("--out-dir DIR", "出力先 (default: data/ml_cv_half_life)") { |v| options[:out_dir] = v }
  opts.on("--cv-script PATH", "CV実行スクリプト (default: scripts/run_timeseries_cv.rb)") { |v| options[:cv_script] = v }
end
parser.parse!

if options.values_at(:from_date, :to_date).any?(&:nil?)
  warn parser.to_s
  exit 1
end
raise "half-lives is empty" if options[:half_lives].empty?

HalfLifeComparer.new(
  from_date: options[:from_date],
  to_date: options[:to_date],
  train_days: options[:train_days],
  valid_days: options[:valid_days],
  step_days: options[:step_days],
  half_lives: options[:half_lives],
  min_sample_weight: options[:min_sample_weight],
  lake_dir: options[:lake_dir],
  db_path: options[:db_path],
  feature_set_version: options[:feature_set_version],
  target_col: options[:target_col],
  out_dir: options[:out_dir],
  cv_script: options[:cv_script]
).run
