# frozen_string_literal: true

module GK
  module FeatureEngineCommon
    module_function

    def smoothed_rate(num, den, prior, strength)
      den_f = den.to_f
      prior_f = prior.to_f
      return prior_f if den_f <= 0.0

      (num.to_f + (prior_f * strength.to_f)) / (den_f + strength.to_f)
    end

    def recent_rate_smoothed_f(stats, threshold_rank, window, prior, strength)
      recent = stats[:recent_ranks].first(window)
      return prior.to_f if recent.empty?

      hits = recent.count { |rank| rank <= threshold_rank }
      smoothed_rate(hits, recent.size, prior, strength)
    end

    def mark_score(mark_symbol)
      case mark_symbol.to_s
      when "◎" then 5.0
      when "○" then 4.0
      when "▲" then 3.0
      when "△" then 2.0
      when "×", "注" then 1.0
      else 0.0
      end
    end

    def enrich_relative_ranks!(rows)
      rows.each do |r|
        r["recent3_vs_hist_top3_delta"] = format("%.6f", r["hist_recent3_top3_rate"].to_f - r["hist_top3_rate"].to_f)
        prev_rank = r["same_meet_prev_day_rank"].to_i
        inv = prev_rank.positive? ? (1.0 / prev_rank) : 0.0
        r["same_meet_prev_day_rank_inv"] = format("%.6f", inv)
        r["same_meet_recent3_synergy"] = format("%.6f", inv * r["hist_recent3_top3_rate"].to_f)
      end

      avg_rank_rank = rank_map(rows) { |r| [safe_avg_rank_sort_value(r["hist_avg_rank"]), r["car_number"].to_i] }
      recent3_top3_rank = rank_map(rows) { |r| [-r["hist_recent3_top3_rate"].to_f, r["car_number"].to_i] }
      recent5_top3_rank = rank_map(rows) { |r| [-r["hist_recent5_top3_rate"].to_f, r["car_number"].to_i] }
      same_meet_prev_day_rank = rank_map(rows) { |r| [safe_same_meet_rank(r["same_meet_prev_day_rank"]), r["car_number"].to_i] }
      same_meet_avg_rank = rank_map(rows) { |r| [safe_avg_rank_sort_value(r["same_meet_avg_rank"]), r["car_number"].to_i] }
      same_meet_recent3_synergy_rank = rank_map(rows) { |r| [-r["same_meet_recent3_synergy"].to_f, r["car_number"].to_i] }
      pair_i_top3_rank = rank_map(rows) { |r| [-r["pair_hist_i_top3_rate_avg"].to_f, r["car_number"].to_i] }
      triplet_i_top3_rank = rank_map(rows) { |r| [-r["triplet_hist_i_top3_rate_avg"].to_f, r["car_number"].to_i] }
      win_rank = rank_map(rows) { |r| [-r["hist_win_rate"].to_f, r["car_number"].to_i] }
      top3_rank = rank_map(rows) { |r| [-r["hist_top3_rate"].to_f, r["car_number"].to_i] }
      mark_rank = rank_map(rows) { |r| [-r["mark_score"].to_f, r["car_number"].to_i] }
      odds_rank = rank_map(rows) { |r| [r["odds_2shatan_min_first"].to_f, r["car_number"].to_i] }

      rows.each do |r|
        car_number = r["car_number"]
        r["race_rel_hist_avg_rank_rank"] = avg_rank_rank[car_number].to_s
        r["race_rel_hist_recent3_top3_rate_rank"] = recent3_top3_rank[car_number].to_s
        r["race_rel_hist_recent5_top3_rate_rank"] = recent5_top3_rank[car_number].to_s
        r["race_rel_same_meet_prev_day_rank"] = same_meet_prev_day_rank[car_number].to_s
        r["race_rel_same_meet_avg_rank_rank"] = same_meet_avg_rank[car_number].to_s
        r["race_rel_same_meet_recent3_synergy_rank"] = same_meet_recent3_synergy_rank[car_number].to_s
        r["race_rel_pair_i_top3_rate_rank"] = pair_i_top3_rank[car_number].to_s
        r["race_rel_triplet_i_top3_rate_rank"] = triplet_i_top3_rank[car_number].to_s
        r["race_rel_hist_win_rate_rank"] = win_rank[car_number].to_s
        r["race_rel_hist_top3_rate_rank"] = top3_rank[car_number].to_s
        r["race_rel_mark_score_rank"] = mark_rank[car_number].to_s
        r["race_rel_odds_2shatan_rank"] = odds_rank[car_number].to_s
      end
    end

    def rank_map(rows, &block)
      rows.sort_by(&block).each_with_index.to_h { |r, i| [r["car_number"], i + 1] }
    end
    private_class_method :rank_map

    def safe_avg_rank_sort_value(v)
      x = v.to_f
      x.zero? ? 999.9 : x
    end
    private_class_method :safe_avg_rank_sort_value

    def safe_same_meet_rank(v)
      x = v.to_i
      x <= 0 ? 999 : x
    end
    private_class_method :safe_same_meet_rank
  end
end
