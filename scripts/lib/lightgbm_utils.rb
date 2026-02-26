# frozen_string_literal: true

module GK
  module LightGBMUtils
    module_function

    def ensure_lightgbm!(message: "lightgbm command not found")
      return if system("command -v lightgbm >/dev/null 2>&1")

      raise message
    end
  end
end
