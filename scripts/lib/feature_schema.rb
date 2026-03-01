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
      hist_recent3_weighted_avg_rank
      hist_recent3_win_rate
      hist_recent3_top3_rate
      recent3_vs_hist_top3_delta
      hist_recent5_weighted_avg_rank
      hist_recent5_win_rate
      hist_recent5_top3_rate
      hist_days_since_last
      same_meet_day_number
      same_meet_prev_day_exists
      same_meet_prev_day_rank
      same_meet_prev_day_top1
      same_meet_prev_day_top3
      same_meet_races
      same_meet_avg_rank
      same_meet_prev_day_rank_inv
      same_meet_recent3_synergy
      pair_hist_count_total
      pair_hist_i_top3_rate_avg
      pair_hist_both_top3_rate_avg
      triplet_hist_count_total
      triplet_hist_i_top3_rate_avg
      triplet_hist_all_top3_rate_avg
      race_rel_hist_avg_rank_rank
      race_rel_hist_recent3_top3_rate_rank
      race_rel_hist_recent5_top3_rate_rank
      race_rel_same_meet_prev_day_rank
      race_rel_same_meet_avg_rank_rank
      race_rel_same_meet_recent3_synergy_rank
      race_rel_pair_i_top3_rate_rank
      race_rel_triplet_i_top3_rate_rank
      race_rel_hist_win_rate_rank
      race_rel_hist_top3_rate_rank
      mark_score
      race_rel_mark_score_rank
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

    def feature_columns(exclude = [])
      FEATURE_COLUMNS - Array(exclude)
    end

    def categorical_features_for(feature_columns)
      feature_columns & CATEGORICAL_FEATURES
    end

    def build_categorical_encoders(rows, feature_columns = FEATURE_COLUMNS)
      categorical_features_for(feature_columns).to_h do |feature|
        values = rows.map { |r| r[feature].to_s }.uniq.sort
        [feature, values.each_with_index.to_h { |v, i| [v, i] }]
      end
    end
  end
end
