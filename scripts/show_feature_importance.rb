#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require_relative "lib/feature_schema"

class FeatureImportanceViewer
  def initialize(model_path:, top_n:)
    @model_path = model_path
    @top_n = top_n
  end

  def run
    rows = parse_importances
    puts "model=#{@model_path}"
    rows.first(@top_n).each do |name, value|
      puts format("%4d %s", value, name)
    end
  end

  private

  def parse_importances
    cols = load_feature_columns
    map = Hash.new(0)
    in_section = false

    File.readlines(@model_path, chomp: true).each do |line|
      if line == "feature_importances:"
        in_section = true
        next
      end
      if in_section
        break if line.empty?

        key, value = line.split("=", 2)
        next if value.nil?

        idx = key.sub("Column_", "").to_i
        map[cols[idx]] = value.to_i
      end
    end

    cols.map { |name| [name, map[name]] }.sort_by { |name, value| [-value, name] }
  end

  def load_feature_columns
    path = File.join(File.dirname(@model_path), "feature_columns.json")
    return GK::FeatureSchema::FEATURE_COLUMNS unless File.exist?(path)

    JSON.parse(File.read(path, encoding: "UTF-8"))
  end
end

options = {
  model_path: File.join("data", "ml", "model.txt"),
  top_n: 20
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: ruby scripts/show_feature_importance.rb [options]"
  opts.on("--model PATH", "model.txt path") { |v| options[:model_path] = v }
  opts.on("--top N", Integer, "show top N features (default: 20)") { |v| options[:top_n] = v }
end
parser.parse!

FeatureImportanceViewer.new(
  model_path: options[:model_path],
  top_n: options[:top_n]
).run
