#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"

class FeatureSetComparer
  def initialize(top3_full:, top3_noplayer:, top1_full:, top1_noplayer:, out_path:, tie_threshold:)
    @top3_full = top3_full
    @top3_noplayer = top3_noplayer
    @top1_full = top1_full
    @top1_noplayer = top1_noplayer
    @out_path = out_path
    @tie_threshold = tie_threshold.to_f
  end

  def run
    top3 = compare_pair(
      target: "top3",
      full_path: @top3_full,
      noplayer_path: @top3_noplayer,
      primary_metric: "top3_exact_match_rate",
      secondary_metric: "winner_hit_rate"
    )
    top1 = compare_pair(
      target: "top1",
      full_path: @top1_full,
      noplayer_path: @top1_noplayer,
      primary_metric: "winner_hit_rate",
      secondary_metric: "auc"
    )

    result = {
      "version" => 1,
      "tie_threshold" => @tie_threshold,
      "recommended" => {
        "top3_feature_set" => top3.fetch("recommended_feature_set"),
        "top1_feature_set" => top1.fetch("recommended_feature_set")
      },
      "comparisons" => {
        "top3" => top3,
        "top1" => top1
      }
    }

    File.write(@out_path, JSON.pretty_generate(result))
    warn "feature_set_comparison=#{@out_path}"
    warn "recommended_top3=#{result.dig('recommended', 'top3_feature_set')}"
    warn "recommended_top1=#{result.dig('recommended', 'top1_feature_set')}"
  end

  private

  def compare_pair(target:, full_path:, noplayer_path:, primary_metric:, secondary_metric:)
    full = JSON.parse(File.read(full_path, encoding: "UTF-8"))
    noplayer = JSON.parse(File.read(noplayer_path, encoding: "UTF-8"))

    full_primary = metric_value(full, primary_metric)
    noplayer_primary = metric_value(noplayer, primary_metric)
    full_secondary = metric_value(full, secondary_metric)
    noplayer_secondary = metric_value(noplayer, secondary_metric)

    primary_diff = full_primary - noplayer_primary
    secondary_diff = full_secondary - noplayer_secondary

    recommended =
      if primary_diff.abs >= @tie_threshold
        primary_diff >= 0 ? "full" : "noplayer"
      elsif secondary_diff >= 0
        "full"
      else
        "noplayer"
      end

    {
      "target" => target,
      "primary_metric" => primary_metric,
      "secondary_metric" => secondary_metric,
      "recommended_feature_set" => recommended,
      "full" => {
        "path" => full_path,
        "metrics" => {
          primary_metric => full_primary,
          secondary_metric => full_secondary,
          "auc" => metric_value(full, "auc")
        }
      },
      "noplayer" => {
        "path" => noplayer_path,
        "metrics" => {
          primary_metric => noplayer_primary,
          secondary_metric => noplayer_secondary,
          "auc" => metric_value(noplayer, "auc")
        }
      },
      "diff" => {
        primary_metric => primary_diff,
        secondary_metric => secondary_diff
      }
    }
  end

  def metric_value(summary, metric)
    value = summary[metric]
    return 0.0 if value.nil?

    value.to_f
  end
end

options = {
  top3_full: File.join("data", "ml", "eval_summary.json"),
  top3_noplayer: File.join("data", "ml_noplayer", "tuning_v2", "trial_024", "eval_summary.json"),
  top1_full: File.join("data", "ml_top1", "tuning_v2", "trial_029", "eval_summary.json"),
  top1_noplayer: File.join("data", "ml_top1_noplayer", "tuning_v2", "trial_025", "eval_summary.json"),
  out_path: File.join("data", "ml", "feature_set_comparison.json"),
  tie_threshold: 0.0
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: ruby scripts/compare_feature_sets.rb [options]"
  opts.on("--top3-full PATH", "top3 full eval_summary.json path") { |v| options[:top3_full] = v }
  opts.on("--top3-noplayer PATH", "top3 noplayer eval_summary.json path") { |v| options[:top3_noplayer] = v }
  opts.on("--top1-full PATH", "top1 full eval_summary.json path") { |v| options[:top1_full] = v }
  opts.on("--top1-noplayer PATH", "top1 noplayer eval_summary.json path") { |v| options[:top1_noplayer] = v }
  opts.on("--out PATH", "output json path") { |v| options[:out_path] = v }
  opts.on("--tie-threshold X", Float, "absolute diff threshold for primary metric (default: 0.0)") { |v| options[:tie_threshold] = v }
end
parser.parse!

FeatureSetComparer.new(
  top3_full: options[:top3_full],
  top3_noplayer: options[:top3_noplayer],
  top1_full: options[:top1_full],
  top1_noplayer: options[:top1_noplayer],
  out_path: options[:out_path],
  tie_threshold: options[:tie_threshold]
).run
