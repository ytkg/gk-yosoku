# frozen_string_literal: true

require "digest"
require "json"

module GK
  module ModelManifest
    module_function

    REQUIRED_KEYS = %w[
      model_id
      target_col
      feature_set_version
      feature_columns_digest
      train_window
      valid_window
      metrics
    ].freeze

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

    def validate_required_keys!(manifest)
      return if manifest.nil?

      missing = REQUIRED_KEYS.reject { |k| manifest.key?(k) }
      raise "model manifest missing keys: #{missing.join(',')}" unless missing.empty?

      validate_window_key!(manifest, "train_window")
      validate_window_key!(manifest, "valid_window")
    end

    def summary(manifest)
      return nil if manifest.nil?

      {
        "model_id" => manifest["model_id"],
        "target_col" => manifest["target_col"],
        "feature_set_version" => manifest["feature_set_version"],
        "feature_columns_digest" => manifest["feature_columns_digest"],
        "train_window" => manifest["train_window"],
        "valid_window" => manifest["valid_window"]
      }
    end

    def validate_window_key!(manifest, key)
      window = manifest[key]
      raise "model manifest invalid #{key}: expected object" unless window.is_a?(Hash)

      missing = %w[from to].reject { |k| window.key?(k) }
      raise "model manifest invalid #{key}: missing #{missing.join(',')}" unless missing.empty?
    end
    private_class_method :validate_window_key!
  end
end
