# frozen_string_literal: true

require "json"

module GK
  module SplitSummary
    module_function

    def load(path)
      return nil if path.nil? || path.empty? || !File.exist?(path)

      JSON.parse(File.read(path, encoding: "UTF-8"))
    rescue JSON::ParserError
      nil
    end

    def format_for_log(summary)
      return nil unless summary.is_a?(Hash)

      split_id = summary["split_id"]
      emit_csv = summary["emit_csv"]
      "split_summary split_id=#{split_id} emit_csv=#{emit_csv}"
    end
  end
end
