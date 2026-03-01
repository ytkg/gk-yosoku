# frozen_string_literal: true

require "json"

module GK
  module ExoticScoring
    DEFAULT_PARAMS = {
      "win_temperature" => 0.2,
      "exacta" => {
        "win_exp" => 1.0,
        "second_exp" => 1.0,
        "second_win_exp" => 0.0
      },
      "trifecta" => {
        "win_exp" => 1.0,
        "second_exp" => 1.0,
        "third_exp" => 1.0
      }
    }.freeze

    module_function

    def default_params
      deep_copy(DEFAULT_PARAMS)
    end

    def load_profile(path)
      raw = JSON.parse(File.read(path, encoding: "UTF-8"))
      raw.is_a?(Hash) ? (raw["params"] || raw) : {}
    end

    def merge_params(base, overrides)
      out = deep_copy(base)
      deep_merge!(out, symbolize_to_string_keys(overrides || {}))
      normalize_params(out)
    end

    def normalize_params(params)
      out = deep_copy(params || {})
      out["win_temperature"] = positive_or_default(out["win_temperature"], DEFAULT_PARAMS["win_temperature"])

      out["exacta"] ||= {}
      out["exacta"]["win_exp"] = positive_or_default(out["exacta"]["win_exp"], DEFAULT_PARAMS["exacta"]["win_exp"])
      out["exacta"]["second_exp"] = positive_or_default(out["exacta"]["second_exp"], DEFAULT_PARAMS["exacta"]["second_exp"])
      out["exacta"]["second_win_exp"] = nonnegative_or_default(out["exacta"]["second_win_exp"], DEFAULT_PARAMS["exacta"]["second_win_exp"])

      out["trifecta"] ||= {}
      out["trifecta"]["win_exp"] = positive_or_default(out["trifecta"]["win_exp"], DEFAULT_PARAMS["trifecta"]["win_exp"])
      out["trifecta"]["second_exp"] = positive_or_default(out["trifecta"]["second_exp"], DEFAULT_PARAMS["trifecta"]["second_exp"])
      out["trifecta"]["third_exp"] = positive_or_default(out["trifecta"]["third_exp"], DEFAULT_PARAMS["trifecta"]["third_exp"])
      out
    end

    def clamp01(x)
      v = x.to_f
      return 0.0 if v.nan? || v.negative?
      return 1.0 if v > 1.0

      v
    end

    def win_probs(cars, win_temperature, car_key:, win_key:)
      exps = cars.to_h do |c|
        z = c.fetch(win_key).to_f / win_temperature.to_f
        [c.fetch(car_key).to_i, Math.exp(z)]
      end
      sum = exps.values.sum
      exps.transform_values { |v| v / sum }
    end

    def score_exacta(p_win:, p_top3:, first_car:, second_car:, params:)
      conf = params.fetch("exacta")
      (pow_prob(p_win[first_car], conf["win_exp"]) *
        pow_prob(p_top3[second_car], conf["second_exp"]) *
        pow_prob(p_win[second_car], conf["second_win_exp"]))
    end

    def score_trifecta(p_win:, p_top3:, first_car:, second_car:, third_car:, params:)
      conf = params.fetch("trifecta")
      (pow_prob(p_win[first_car], conf["win_exp"]) *
        pow_prob(p_top3[second_car], conf["second_exp"]) *
        pow_prob(p_top3[third_car], conf["third_exp"]))
    end

    def format_score(value)
      format("%.17g", value.to_f)
    end

    def pow_prob(prob, exponent)
      p = [clamp01(prob), 1.0e-12].max
      p**exponent.to_f
    end

    def positive_or_default(value, default)
      f = value.to_f
      return default if f.nan? || f <= 0.0

      f
    end

    def nonnegative_or_default(value, default)
      f = value.to_f
      return default if f.nan? || f.negative?

      f
    end

    def symbolize_to_string_keys(obj)
      case obj
      when Hash
        obj.each_with_object({}) do |(k, v), h|
          h[k.to_s] = symbolize_to_string_keys(v)
        end
      when Array
        obj.map { |v| symbolize_to_string_keys(v) }
      else
        obj
      end
    end

    def deep_copy(obj)
      Marshal.load(Marshal.dump(obj))
    end

    def deep_merge!(dst, src)
      src.each do |k, v|
        if dst[k].is_a?(Hash) && v.is_a?(Hash)
          deep_merge!(dst[k], v)
        else
          dst[k] = v
        end
      end
    end
  end
end
