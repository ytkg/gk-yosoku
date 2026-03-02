# frozen_string_literal: true

require_relative "../duckdb_runner"

module GK
  module Storage
    class DuckDBClient
      def initialize(db_path:)
        @db_path = db_path
      end

      def ensure_available!(message: "duckdb command not found")
        GK::DuckDBRunner.ensure_duckdb!(message: message)
      end

      def run_sql!(sql:)
        GK::DuckDBRunner.run_sql!(db_path: @db_path, sql: sql)
      end

      def sql_quote(str)
        GK::DuckDBRunner.sql_quote(str)
      end
    end
  end
end
