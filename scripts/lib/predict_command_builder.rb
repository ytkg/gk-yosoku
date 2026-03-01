# frozen_string_literal: true

module GK
  module PredictCommandBuilder
    module_function

    ARG_MAP = {
      "url" => "--url",
      "model_top3" => "--model-top3",
      "encoders_top3" => "--encoders-top3",
      "model_top1" => "--model-top1",
      "encoders_top1" => "--encoders-top1",
      "model_exacta" => "--model-exacta",
      "encoders_exacta" => "--encoders-exacta",
      "raw_dir" => "--raw-dir",
      "cache_dir" => "--cache-dir",
      "win_temperature" => "--win-temperature",
      "exotic_profile" => "--exotic-profile",
      "exacta_win_exp" => "--exacta-win-exp",
      "exacta_second_exp" => "--exacta-second-exp",
      "exacta_second_win_exp" => "--exacta-second-win-exp",
      "trifecta_win_exp" => "--trifecta-win-exp",
      "trifecta_second_exp" => "--trifecta-second-exp",
      "trifecta_third_exp" => "--trifecta-third-exp",
      "exacta_top" => "--exacta-top",
      "trifecta_top" => "--trifecta-top",
      "no_bet_gap_threshold" => "--bet-gap-threshold",
      "exacta_min_ev" => "--exacta-min-ev",
      "bankroll" => "--bankroll",
      "unit" => "--unit",
      "kelly_cap" => "--kelly-cap",
      "bet_style" => "--bet-style"
    }.freeze

    def build(options)
      args = []
      normalized = options.transform_keys(&:to_s)

      ARG_MAP.each do |key, flag|
        value = normalized[key]
        next if value.nil? || value.to_s.empty?

        args << flag << value.to_s
      end

      unless normalized["use_exacta_model"].nil?
        args << (truthy?(normalized["use_exacta_model"]) ? "--exacta-model" : "--no-exacta-model")
      end
      unless normalized["use_cache"].nil?
        args << (truthy?(normalized["use_cache"]) ? "--cache" : "--no-cache")
      end

      args
    end

    def truthy?(value)
      return value if value == true || value == false

      %w[1 true yes on].include?(value.to_s.downcase)
    end
    private_class_method :truthy?
  end
end
