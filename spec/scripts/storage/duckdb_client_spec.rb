# frozen_string_literal: true

require "spec_helper"
require_relative "../../../scripts/lib/storage/duckdb_client"

RSpec.describe GK::Storage::DuckDBClient do
  it "duckdbコマンド経由でSQLを実行できる" do
    Dir.mktmpdir("spec-duckdb-client-") do |tmp|
      bin_dir = File.join(tmp, "bin")
      create_fake_duckdb(bin_dir)
      old_path = ENV.fetch("PATH", nil)
      ENV["PATH"] = "#{bin_dir}:#{old_path}"

      begin
        db_path = File.join(tmp, "duckdb", "test.duckdb")
        out_path = File.join(tmp, "out", "result.csv")
        client = described_class.new(db_path: db_path)

        expect { client.ensure_available! }.not_to raise_error
        client.run_sql!(sql: "COPY (SELECT 1) TO #{client.sql_quote(out_path)} (HEADER, DELIMITER ',');")
        expect(File).to exist(out_path)
      ensure
        ENV["PATH"] = old_path
      end
    end
  end
end
