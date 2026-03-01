# frozen_string_literal: true

require_relative "feature_schema"

module GK
  module ExactaFeatureSchema
    TARGET_COLUMN = "exacta_top1"

    META_COLUMNS = %w[
      race_id
      race_date
      venue
      race_number
      first_car_number
      first_player_name
      second_car_number
      second_player_name
      first_rank
      second_rank
    ].freeze

    SOURCE_FEATURE_COLUMNS = GK::FeatureSchema::FEATURE_COLUMNS
    SOURCE_NUMERIC_FEATURES = GK::FeatureSchema::NUMERIC_FEATURES
    SOURCE_CATEGORICAL_FEATURES = GK::FeatureSchema::CATEGORICAL_FEATURES

    FEATURE_COLUMNS = begin
      cols = []
      SOURCE_FEATURE_COLUMNS.each do |col|
        cols << "first_#{col}"
        cols << "second_#{col}"
      end
      SOURCE_NUMERIC_FEATURES.each do |col|
        cols << "diff_#{col}"
      end
      cols.freeze
    end

    CATEGORICAL_FEATURES = begin
      cols = []
      SOURCE_CATEGORICAL_FEATURES.each do |col|
        cols << "first_#{col}"
        cols << "second_#{col}"
      end
      cols.freeze
    end

    module_function

    def output_headers
      META_COLUMNS + [TARGET_COLUMN] + FEATURE_COLUMNS
    end

    def feature_columns(exclude = [])
      FEATURE_COLUMNS - Array(exclude)
    end

    def categorical_features_for(feature_columns)
      feature_columns & CATEGORICAL_FEATURES
    end

    def build_categorical_encoders(rows, feature_columns)
      categorical_features_for(feature_columns).to_h do |feature|
        values = rows.map { |r| r[feature].to_s }.uniq.sort
        [feature, values.each_with_index.to_h { |v, i| [v, i] }]
      end
    end

    def to_float_string(v)
      return "0.0" if v.nil? || v.to_s.strip.empty?

      v.to_f.to_s
    end
  end
end
