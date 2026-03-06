#!/usr/bin/env ruby
# frozen_string_literal: true

require "csv"
require "fileutils"
require "json"
require "open3"
require "optparse"
require_relative "lib/duckdb_runner"
require_relative "lib/exacta_feature_schema"
require_relative "lib/lightgbm_utils"

class ExactaLightGBMEvaluator
  DEFAULT_NS = [1, 3, 5, 10, 20].freeze

  def initialize(model_path:, valid_csv:, valid_parquet:, db_path:, encoder_path:, out_dir:, target_col:, exacta_top:, ns:)
    @model_path = model_path
    @valid_csv = valid_csv
    @valid_parquet = valid_parquet
    @db_path = db_path
    @encoder_path = encoder_path
    @out_dir = out_dir
    @target_col = target_col
    @exacta_top = exacta_top
    @ns = ns
    @feature_columns = load_feature_columns
    @categorical_features = load_categorical_features
    FileUtils.mkdir_p(@out_dir)
  end

  def run
    check_lightgbm!

    rows = CSV.read(resolved_valid_csv, headers: true, encoding: "UTF-8").map(&:to_h)
    raise "empty valid rows" if rows.empty?
    raise "missing target column: #{@target_col}" unless rows.first.key?(@target_col)
    encoders = JSON.parse(File.read(@encoder_path, encoding: "UTF-8"))

    valid_tsv = File.join(@out_dir, "valid_eval.tsv")
    pred_path = File.join(@out_dir, "valid_pred.txt")
    pred_csv = File.join(@out_dir, "valid_pair_pred.csv")
    exacta_csv = File.join(@out_dir, "exacta_pred.csv")
    summary_path = File.join(@out_dir, "eval_summary.json")

    write_eval_tsv(valid_tsv, rows, encoders)
    run_predict(valid_tsv, pred_path)
    preds = File.readlines(pred_path, chomp: true).map(&:to_f)
    raise "prediction size mismatch: rows=#{rows.size} preds=#{preds.size}" if rows.size != preds.size

    rows_with_score = rows.each_with_index.map { |r, i| r.merge("score" => preds[i]) }
    write_pair_pred_csv(pred_csv, rows_with_score)
    write_exacta_pred_csv(exacta_csv, rows_with_score)

    summary = evaluate(rows_with_score)
    File.write(summary_path, JSON.pretty_generate(summary))

    warn "auc=#{format('%.6f', summary['auc'])}"
    warn "exacta_hit@1=#{format('%.6f', summary.dig('hit_at', '1'))}"
    warn "exacta_hit@3=#{format('%.6f', summary.dig('hit_at', '3'))}"
    warn "summary=#{summary_path}"
  end

  private

  def check_lightgbm!
    GK::LightGBMUtils.ensure_lightgbm!
  end

  def resolved_valid_csv
    return @valid_csv if @valid_parquet.nil? || @valid_parquet.empty?

    materialize_parquet_to_csv(@valid_parquet, File.join(@out_dir, "valid_from_parquet.csv"))
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

  def write_eval_tsv(path, rows, encoders)
    File.open(path, "w") do |f|
      rows.each do |r|
        y = r[@target_col].to_i
        xs = @feature_columns.map do |name|
          if @categorical_features.include?(name)
            (encoders.fetch(name, {})[r[name].to_s] || -1).to_s
          else
            GK::ExactaFeatureSchema.to_float_string(r[name])
          end
        end
        f.puts(([y] + xs).join("\t"))
      end
    end
  end

  def run_predict(valid_tsv, pred_path)
    conf_path = File.join(@out_dir, "lightgbm_predict.conf")
    File.write(conf_path, <<~CONF)
      task=predict
      data=#{valid_tsv}
      input_model=#{@model_path}
      output_result=#{pred_path}
      header=false
    CONF

    out, err, status = Open3.capture3("lightgbm", "config=#{conf_path}")
    raise "lightgbm predict failed: #{err}\n#{out}" unless status.success?
  end

  def write_pair_pred_csv(path, rows)
    headers = GK::ExactaFeatureSchema::META_COLUMNS + [@target_col, "score"]
    CSV.open(path, "w", write_headers: true, headers: headers) do |csv|
      rows.each do |r|
        csv << headers.map do |h|
          h == "score" ? format_score(r[h]) : r[h]
        end
      end
    end
  end

  def write_exacta_pred_csv(path, rows)
    headers = %w[
      race_id race_date venue race_number
      first_car_number first_player_name
      second_car_number second_player_name
      score
    ]
    CSV.open(path, "w", write_headers: true, headers: headers) do |csv|
      rows.group_by { |r| r["race_id"] }.each_value do |race_rows|
        race_rows.sort_by { |r| -r["score"].to_f }.first(@exacta_top).each do |r|
          csv << headers.map do |h|
            h == "score" ? format_score(r[h]) : r[h]
          end
        end
      end
    end
  end

  def evaluate(rows)
    y_true = rows.map { |r| r[@target_col].to_i }
    y_score = rows.map { |r| r["score"].to_f }
    grouped = rows.group_by { |r| r["race_id"] }
    hit_at = @ns.to_h do |n|
      hit = grouped.count do |_race_id, rs|
        actual = rs.find { |r| r[@target_col].to_i == 1 }
        next false if actual.nil?

        picked = rs.sort_by { |r| -r["score"].to_f }.first(n)
        picked.any? do |r|
          r["first_car_number"] == actual["first_car_number"] &&
            r["second_car_number"] == actual["second_car_number"]
        end
      end
      [n.to_s, hit.to_f / grouped.size]
    end

    {
      "rows" => rows.size,
      "races" => grouped.size,
      "auc" => auc(y_true, y_score),
      "hit_at" => hit_at
    }
  end

  def auc(y_true, y_score)
    pairs = y_true.zip(y_score).sort_by { |(_y, s)| s }
    n_pos = y_true.count(1)
    n_neg = y_true.count(0)
    return 0.0 if n_pos.zero? || n_neg.zero?

    ranks = Array.new(pairs.size, 0.0)
    i = 0
    while i < pairs.size
      j = i
      j += 1 while j < pairs.size && pairs[j][1] == pairs[i][1]
      avg_rank = (i + 1 + j) / 2.0
      (i...j).each { |k| ranks[k] = avg_rank }
      i = j
    end

    sum_pos_ranks = 0.0
    pairs.each_with_index do |(y, _s), idx|
      sum_pos_ranks += ranks[idx] if y == 1
    end

    (sum_pos_ranks - (n_pos * (n_pos + 1) / 2.0)) / (n_pos * n_neg)
  end

  def load_feature_columns
    path = File.join(File.dirname(@model_path), "feature_columns.json")
    return GK::ExactaFeatureSchema::FEATURE_COLUMNS unless File.exist?(path)

    JSON.parse(File.read(path, encoding: "UTF-8"))
  end

  def load_categorical_features
    path = File.join(File.dirname(@model_path), "categorical_features.json")
    return GK::ExactaFeatureSchema.categorical_features_for(@feature_columns) unless File.exist?(path)

    JSON.parse(File.read(path, encoding: "UTF-8"))
  end

  def format_score(value)
    format("%.17g", value.to_f)
  end
end

options = {
  model_path: File.join("data", "ml_exacta", "model.txt"),
  valid_csv: File.join("data", "ml_exacta", "valid.csv"),
  valid_parquet: nil,
  db_path: File.join("data", "duckdb", "gk_yosoku.duckdb"),
  encoder_path: File.join("data", "ml_exacta", "encoders.json"),
  out_dir: File.join("data", "ml_exacta"),
  target_col: GK::ExactaFeatureSchema::TARGET_COLUMN,
  exacta_top: 20,
  ns: ExactaLightGBMEvaluator::DEFAULT_NS
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: ruby scripts/evaluate_exacta_lightgbm.rb [options]"
  opts.on("--model PATH", "LightGBM model path") { |v| options[:model_path] = v }
  opts.on("--valid-csv PATH", "validation CSV path (compatibility mode)") { |v| options[:valid_csv] = v }
  opts.on("--valid-parquet PATH", "validation parquet path (recommended)") { |v| options[:valid_parquet] = v }
  opts.on("--db-path PATH", "DuckDB DB path for parquet input") { |v| options[:db_path] = v }
  opts.on("--encoders PATH", "encoders.json path") { |v| options[:encoder_path] = v }
  opts.on("--out-dir DIR", "output dir") { |v| options[:out_dir] = v }
  opts.on("--target-col NAME", "target column name (default: exacta_top1)") { |v| options[:target_col] = v }
  opts.on("--exacta-top N", Integer, "top N exacta rows per race for exacta_pred.csv (default: 20)") { |v| options[:exacta_top] = v }
  opts.on("--ns LIST", "comma-separated hit@N list, e.g. 1,3,5,10,20") { |v| options[:ns] = v.split(",").map(&:to_i).select { |n| n > 0 } }
end
parser.parse!

raise "ns is empty" if options[:ns].empty?

ExactaLightGBMEvaluator.new(
  model_path: options[:model_path],
  valid_csv: options[:valid_csv],
  valid_parquet: options[:valid_parquet],
  db_path: options[:db_path],
  encoder_path: options[:encoder_path],
  out_dir: options[:out_dir],
  target_col: options[:target_col],
  exacta_top: options[:exacta_top],
  ns: options[:ns]
).run
