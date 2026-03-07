#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"

class HalfLifeDecision
  def initialize(summary_path:, current_half_life:, metric:, min_improvement:, out_path:)
    @summary_path = summary_path
    @current_half_life = current_half_life.to_f
    @metric = metric
    @min_improvement = min_improvement.to_f
    @out_path = out_path
  end

  def run
    summary = JSON.parse(File.read(@summary_path, encoding: "UTF-8"))
    rows = summary.fetch("rows")
    recommended = summary.fetch("recommended_half_life_days").to_f

    best_row = rows.find { |row| row["half_life_days"].to_f == recommended }
    raise "recommended row not found: #{recommended}" if best_row.nil?

    current_row = rows.find { |row| row["half_life_days"].to_f == @current_half_life }
    current_metric = current_row.nil? ? nil : metric_value(current_row)
    best_metric = metric_value(best_row)

    improvement = current_metric.nil? ? nil : (best_metric - current_metric)
    should_adopt = current_metric.nil? || improvement >= @min_improvement
    selected = should_adopt ? recommended : @current_half_life

    decision = {
      "summary_path" => @summary_path,
      "metric" => @metric,
      "min_improvement" => @min_improvement,
      "current_half_life_days" => @current_half_life,
      "recommended_half_life_days" => recommended,
      "selected_half_life_days" => selected,
      "current_metric" => current_metric,
      "recommended_metric" => best_metric,
      "improvement" => improvement,
      "should_adopt_recommendation" => should_adopt
    }

    File.write(@out_path, JSON.pretty_generate(decision))
    warn "half_life_decision=#{@out_path}"
    warn "selected_half_life_days=#{selected}"
  end

  private

  def metric_value(row)
    value = row[@metric]
    return 0.0 if value.nil?

    value.to_f
  end
end

options = {
  summary_path: File.join("data", "ml_cv_half_life", "half_life_summary.json"),
  current_half_life: 120.0,
  metric: "winner_hit_rate_mean",
  min_improvement: 0.01,
  out_path: File.join("data", "ml_cv_half_life", "half_life_decision.json")
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: ruby scripts/decide_time_decay_half_life.rb [options]"
  opts.on("--summary PATH", "half_life_summary.json path") { |v| options[:summary_path] = v }
  opts.on("--current-half-life N", Float, "current half life days (default: 120)") { |v| options[:current_half_life] = v }
  opts.on("--metric NAME", "metric key in rows (default: winner_hit_rate_mean)") { |v| options[:metric] = v }
  opts.on("--min-improvement X", Float, "minimum improvement to adopt recommendation (default: 0.01)") { |v| options[:min_improvement] = v }
  opts.on("--out PATH", "output decision json path") { |v| options[:out_path] = v }
end
parser.parse!

HalfLifeDecision.new(
  summary_path: options[:summary_path],
  current_half_life: options[:current_half_life],
  metric: options[:metric],
  min_improvement: options[:min_improvement],
  out_path: options[:out_path]
).run
