# frozen_string_literal: true

module GK
  module FeatureSchema
    CATEGORICAL_FEATURES = %w[venue player_name mark_symbol leg_style].freeze
    NUMERIC_FEATURES = %w[
      race_number
      car_number
      hist_races
      hist_win_rate
      hist_top3_rate
      hist_avg_rank
      hist_last_rank
      hist_recent5_weighted_avg_rank
      hist_recent5_win_rate
      hist_recent5_top3_rate
      hist_days_since_last
      race_rel_hist_win_rate_rank
      race_rel_hist_top3_rate_rank
      odds_2shatan_min_first
      race_rel_odds_2shatan_rank
      race_field_size
    ].freeze
    FEATURE_COLUMNS = (CATEGORICAL_FEATURES + NUMERIC_FEATURES).freeze

    module_function

    def to_float_string(v)
      return "0.0" if v.nil? || v.to_s.strip.empty?

      v.to_f.to_s
    end

    def build_categorical_encoders(rows)
      CATEGORICAL_FEATURES.to_h do |feature|
        values = rows.map { |r| r[feature].to_s }.uniq.sort
        [feature, values.each_with_index.to_h { |v, i| [v, i] }]
      end
    end
  end
end
