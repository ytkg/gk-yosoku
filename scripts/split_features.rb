#!/usr/bin/env ruby
# frozen_string_literal: true

require "csv"
require "date"
require "fileutils"
require "optparse"

class FeatureSplitter
  def initialize(from_date:, to_date:, train_to:, in_dir:, out_dir:)
    @from_date = Date.iso8601(from_date)
    @to_date = Date.iso8601(to_date)
    @train_to = Date.iso8601(train_to)
    raise ArgumentError, "from_date must be <= to_date" if @from_date > @to_date
    raise ArgumentError, "train_to must be within from_date..to_date" if @train_to < @from_date || @train_to >= @to_date

    @in_dir = in_dir
    @out_dir = out_dir
    FileUtils.mkdir_p(@out_dir)
  end

  def run
    rows = read_rows
    train_rows, valid_rows = rows.partition { |r| Date.iso8601(r["race_date"]) <= @train_to }

    write_csv(File.join(@out_dir, "train.csv"), train_rows, rows.headers)
    write_csv(File.join(@out_dir, "valid.csv"), valid_rows, rows.headers)

    warn "rows_total=#{rows.size} train=#{train_rows.size} valid=#{valid_rows.size}"
    warn "races_train=#{race_count(train_rows)} races_valid=#{race_count(valid_rows)}"
  end

  private

  def read_rows
    merged = []
    headers = nil

    (@from_date..@to_date).each do |date|
      path = File.join(@in_dir, "features_#{date.strftime('%Y%m%d')}.csv")
      raise "not found: #{path}" unless File.exist?(path)

      csv = CSV.read(path, headers: true, encoding: "UTF-8")
      headers ||= csv.headers
      raise "header mismatch: #{path}" unless csv.headers == headers
      merged.concat(csv.map(&:to_h))
    end

    CsvRows.new(headers, merged)
  end

  def write_csv(path, rows, headers)
    CSV.open(path, "w", write_headers: true, headers: headers) do |csv|
      rows.each { |r| csv << headers.map { |h| r[h] } }
    end
  end

  def race_count(rows)
    rows.map { |r| r["race_id"] }.uniq.size
  end

  class CsvRows
    attr_reader :headers

    def initialize(headers, rows)
      @headers = headers
      @rows = rows
    end

    def size
      @rows.size
    end

    def partition(&block)
      @rows.partition(&block)
    end
  end
end

options = {
  from_date: nil,
  to_date: nil,
  train_to: nil,
  in_dir: File.join("data", "features"),
  out_dir: File.join("data", "ml")
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: ruby scripts/split_features.rb --from-date YYYY-MM-DD --to-date YYYY-MM-DD --train-to YYYY-MM-DD"
  opts.on("--from-date DATE", "開始日 (YYYY-MM-DD)") { |v| options[:from_date] = v }
  opts.on("--to-date DATE", "終了日 (YYYY-MM-DD)") { |v| options[:to_date] = v }
  opts.on("--train-to DATE", "学習データの最終日 (YYYY-MM-DD)") { |v| options[:train_to] = v }
  opts.on("--in-dir DIR", "features CSVの入力先") { |v| options[:in_dir] = v }
  opts.on("--out-dir DIR", "train/valid CSVの出力先") { |v| options[:out_dir] = v }
end
parser.parse!

if options.values_at(:from_date, :to_date, :train_to).any?(&:nil?)
  warn parser.to_s
  exit 1
end

FeatureSplitter.new(
  from_date: options[:from_date],
  to_date: options[:to_date],
  train_to: options[:train_to],
  in_dir: options[:in_dir],
  out_dir: options[:out_dir]
).run
