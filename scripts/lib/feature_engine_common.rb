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
  end
end
