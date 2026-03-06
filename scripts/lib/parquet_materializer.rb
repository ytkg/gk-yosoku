# frozen_string_literal: true

require_relative "duckdb_runner"

module GK
  module ParquetMaterializer
    module_function

    def to_csv!(parquet_path:, out_csv_path:, db_path:, missing_message: "duckdb command not found for parquet input")
      GK::DuckDBRunner.ensure_duckdb!(message: missing_message)
      sql = <<~SQL
        COPY (
          SELECT *
          FROM read_parquet(#{GK::DuckDBRunner.sql_quote(parquet_path)})
        )
        TO #{GK::DuckDBRunner.sql_quote(out_csv_path)}
        (HEADER, DELIMITER ',');
      SQL
      GK::DuckDBRunner.run_sql!(db_path: db_path, sql: sql)
      out_csv_path
    end
  end
end
