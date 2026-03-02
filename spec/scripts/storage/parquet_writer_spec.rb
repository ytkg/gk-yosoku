# frozen_string_literal: true

require "spec_helper"
require_relative "../../../scripts/lib/storage/duckdb_client"
require_relative "../../../scripts/lib/storage/parquet_writer"

RSpec.describe GK::Storage::ParquetWriter do
  it "CSVからParquetを書き出せる" do
    Dir.mktmpdir("spec-parquet-writer-") do |tmp|
      bin_dir = File.join(tmp, "bin")
      create_fake_duckdb(bin_dir)
      old_path = ENV.fetch("PATH", nil)
      ENV["PATH"] = "#{bin_dir}:#{old_path}"

      begin
        in_csv = File.join(tmp, "raw", "input.csv")
        out_path = File.join(tmp, "lake", "output.parquet")
        write_csv(in_csv, %w[class rank], [{ "class" => "l1", "rank" => "1" }])

        client = GK::Storage::DuckDBClient.new(db_path: File.join(tmp, "duckdb", "test.duckdb"))
        writer = described_class.new(duckdb_client: client)

        writer.copy_results_csv_to_parquet(csv_path: in_csv, out_path: out_path)
        expect(File).to exist(out_path)
      ensure
        ENV["PATH"] = old_path
      end
    end
  end
end
