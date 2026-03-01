# frozen_string_literal: true

require "digest"
require "json"

module GK
  module ModelManifest
    module_function

    def feature_columns_digest(feature_columns)
      Digest::SHA256.hexdigest(Array(feature_columns).join("\n"))
    end

    def build(model_id:, target_col:, feature_set_version:, feature_columns:, train_from:, train_to:, valid_from:, valid_to:, metrics:)
      {
        "model_id" => model_id,
        "target_col" => target_col,
        "feature_set_version" => feature_set_version,
        "feature_columns_digest" => feature_columns_digest(feature_columns),
        "train_window" => {
          "from" => train_from,
          "to" => train_to
        },
        "valid_window" => {
          "from" => valid_from,
          "to" => valid_to
        },
        "metrics" => metrics
      }
    end

    def load(path)
      return nil unless File.exist?(path)

      JSON.parse(File.read(path, encoding: "UTF-8"))
    end

    def validate_feature_columns!(manifest, feature_columns)
      return if manifest.nil?

      expected = manifest["feature_columns_digest"].to_s
      actual = feature_columns_digest(feature_columns)
      return if expected.empty? || expected == actual

      raise "model manifest mismatch: feature_columns_digest expected=#{expected} actual=#{actual}"
    end
  end
end
