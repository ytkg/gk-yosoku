# frozen_string_literal: true

require "fileutils"

module GK
  module Storage
    class ParquetWriter
      def initialize(duckdb_client:)
        @duckdb_client = duckdb_client
      end

      def copy_results_csv_to_parquet(csv_path:, out_path:)
        copy_csv_to_parquet(
          csv_path: csv_path,
          out_path: out_path,
          select_sql: "SELECT *, UPPER(TRIM(COALESCE(class, ''))) AS class_normalized FROM read_csv_auto(%{csv_path}, HEADER=TRUE)"
        )
      end

      def copy_csv_to_parquet(csv_path:, out_path:, select_sql:)
        FileUtils.mkdir_p(File.dirname(out_path))
        quoted_csv = @duckdb_client.sql_quote(csv_path)
        sql = <<~SQL
          COPY (
            #{format(select_sql, csv_path: quoted_csv)}
          )
          TO #{@duckdb_client.sql_quote(out_path)}
          (FORMAT PARQUET, COMPRESSION ZSTD);
        SQL
        @duckdb_client.run_sql!(sql: sql)
      end
    end
  end
end
