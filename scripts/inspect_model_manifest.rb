#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require_relative "lib/model_manifest"

options = {
  manifest: File.join("data", "ml", "model_manifest.json")
}

OptionParser.new do |opts|
  opts.banner = "Usage: ruby scripts/inspect_model_manifest.rb --manifest PATH"
  opts.on("--manifest PATH", "model_manifest.json path") { |v| options[:manifest] = v }
end.parse!

manifest = GK::ModelManifest.load(options[:manifest])
abort("manifest not found: #{options[:manifest]}") if manifest.nil?

GK::ModelManifest.validate_required_keys!(manifest)

summary = {
  "model_id" => manifest["model_id"],
  "target_col" => manifest["target_col"],
  "feature_set_version" => manifest["feature_set_version"],
  "train_window" => manifest["train_window"],
  "valid_window" => manifest["valid_window"],
  "metrics" => manifest["metrics"]
}

puts JSON.pretty_generate(summary)
