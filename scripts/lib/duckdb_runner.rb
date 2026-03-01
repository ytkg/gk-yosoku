# frozen_string_literal: true

require "fileutils"
require "open3"

module GK
  module DuckDBRunner
    module_function

    def ensure_duckdb!(message: "duckdb command not found")
      return if system("command -v duckdb >/dev/null 2>&1")

      raise message
    end

    def run_sql!(db_path:, sql:)
      raise "empty sql" if sql.to_s.strip.empty?

      FileUtils.mkdir_p(File.dirname(db_path))
      out, err, status = Open3.capture3("duckdb", db_path.to_s, stdin_data: sql.to_s)
      return out if status.success?

      raise "duckdb failed: #{err}\n#{out}"
    end

    def sql_quote(str)
      "'#{str.to_s.gsub("'", "''")}'"
    end
  end
end
