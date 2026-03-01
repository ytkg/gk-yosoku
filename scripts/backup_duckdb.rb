#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "optparse"
require "time"

class DuckDBBackup
  def initialize(db_path:, out_dir:, mode:, src_path:)
    @db_path = db_path
    @out_dir = out_dir
    @mode = mode
    @src_path = src_path
  end

  def run
    case @mode
    when "backup"
      run_backup
    when "restore"
      run_restore
    else
      raise "invalid mode: #{@mode}"
    end
  end

  private

  def run_backup
    raise "db not found: #{@db_path}" unless File.exist?(@db_path)

    FileUtils.mkdir_p(@out_dir)
    ts = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
    out = File.join(@out_dir, "gk_yosoku_#{ts}.duckdb")
    FileUtils.cp(@db_path, out)
    warn "backup=#{out}"
  end

  def run_restore
    raise "--src is required for restore mode" if @src_path.to_s.empty?
    raise "src not found: #{@src_path}" unless File.exist?(@src_path)

    FileUtils.mkdir_p(File.dirname(@db_path))
    FileUtils.cp(@src_path, @db_path)
    warn "restore src=#{@src_path} dst=#{@db_path}"
  end
end

options = {
  db_path: File.join("data", "duckdb", "gk_yosoku.duckdb"),
  out_dir: File.join("data", "duckdb_backup"),
  mode: "backup",
  src_path: nil
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: ruby scripts/backup_duckdb.rb [options]"
  opts.on("--db-path PATH", "DuckDB DBファイル (default: data/duckdb/gk_yosoku.duckdb)") { |v| options[:db_path] = v }
  opts.on("--out-dir DIR", "バックアップ先ディレクトリ (default: data/duckdb_backup)") { |v| options[:out_dir] = v }
  opts.on("--mode MODE", "backup or restore (default: backup)") { |v| options[:mode] = v }
  opts.on("--src PATH", "restore時の入力バックアップファイル") { |v| options[:src_path] = v }
end
parser.parse!

DuckDBBackup.new(
  db_path: options[:db_path],
  out_dir: options[:out_dir],
  mode: options[:mode],
  src_path: options[:src_path]
).run
