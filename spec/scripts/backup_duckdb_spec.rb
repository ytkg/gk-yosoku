# frozen_string_literal: true

require "spec_helper"

RSpec.describe "backup_duckdb.rb" do
  it "backup/restore を実行できる" do
    Dir.mktmpdir("spec-backup-duckdb-") do |tmp|
      db_dir = File.join(tmp, "duckdb")
      backup_dir = File.join(tmp, "backup")
      db_path = File.join(db_dir, "gk_yosoku.duckdb")
      FileUtils.mkdir_p(db_dir)
      File.write(db_path, "db-v1")

      _out1, err1, st1 = run_cmd(
        "ruby", "scripts/backup_duckdb.rb",
        "--db-path", db_path,
        "--out-dir", backup_dir,
        "--mode", "backup"
      )
      expect(st1.success?).to be(true), err1
      backup_files = Dir.glob(File.join(backup_dir, "*.duckdb"))
      expect(backup_files).not_to be_empty

      File.write(db_path, "broken")
      _out2, err2, st2 = run_cmd(
        "ruby", "scripts/backup_duckdb.rb",
        "--db-path", db_path,
        "--mode", "restore",
        "--src", backup_files.first
      )
      expect(st2.success?).to be(true), err2
      expect(File.read(db_path, encoding: "UTF-8")).to eq("db-v1")
    end
  end
end
