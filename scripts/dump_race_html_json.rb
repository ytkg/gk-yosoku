#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "net/http"
require "optparse"
require "uri"
require_relative "lib/html_utils"

class RaceHtmlJsonDumper
  def initialize(html_file:, url:, mode:, out:, use_cache:, cache_dir:)
    @html_file = html_file
    @url = url
    @mode = mode
    @out = out
    @use_cache = use_cache
    @cache_dir = cache_dir
    FileUtils.mkdir_p(@cache_dir)
  end

  def run
    html = @html_file.nil? ? fetch_html(@url) : File.read(@html_file, encoding: "UTF-8")
    json_obj =
      if @mode == "basic"
        GK::HtmlUtils.parse_race_detail_json(html)
      else
        GK::HtmlUtils.parse_race_detail_full_json(html)
      end

    json = JSON.pretty_generate(json_obj)
    if @out.to_s.empty?
      puts json
    else
      FileUtils.mkdir_p(File.dirname(@out))
      File.write(@out, json)
      warn "written=#{@out}"
    end
  end

  private

  def fetch_html(url)
    path = File.join(@cache_dir, "race_#{Digest::SHA1.hexdigest(url)}.html")
    return File.read(path, encoding: "UTF-8") if @use_cache && File.exist?(path)

    uri = URI.parse(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 10
    http.read_timeout = 20
    req = Net::HTTP::Get.new(uri.request_uri)
    req["User-Agent"] = "gk-yosoku-dump/1.0"
    req["Accept"] = "text/html,application/xhtml+xml"
    res = http.request(req)
    raise "HTTP #{res.code}: #{url}" unless res.code.to_i == 200

    html = GK::HtmlUtils.normalize_body(res.body, res["content-type"])
    File.write(path, html)
    html
  end
end

options = {
  html_file: nil,
  url: nil,
  mode: "full",
  out: "",
  use_cache: true,
  cache_dir: File.join("data", "raw_html")
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: ruby scripts/dump_race_html_json.rb [--html-file PATH | --url URL] [options]"
  opts.on("--html-file PATH", "ローカルHTMLファイルを読む") { |v| options[:html_file] = v }
  opts.on("--url URL", "レースURLを取得して読む") { |v| options[:url] = v }
  opts.on("--mode MODE", "basic/full (default: full)") { |v| options[:mode] = v }
  opts.on("--out PATH", "JSON出力先（省略時は標準出力）") { |v| options[:out] = v }
  opts.on("--[no-]cache", "URL取得時にHTMLキャッシュを使う（default: true）") { |v| options[:use_cache] = v }
  opts.on("--cache-dir DIR", "URL取得時のHTMLキャッシュ先") { |v| options[:cache_dir] = v }
end
parser.parse!

if options[:html_file].to_s.empty? && options[:url].to_s.empty?
  warn parser.to_s
  exit 1
end
if !options[:html_file].to_s.empty? && !options[:url].to_s.empty?
  warn "--html-file と --url はどちらか片方のみ指定してください"
  exit 1
end
unless %w[basic full].include?(options[:mode])
  warn "--mode は basic/full を指定してください"
  exit 1
end

RaceHtmlJsonDumper.new(
  html_file: options[:html_file].to_s.empty? ? nil : options[:html_file],
  url: options[:url].to_s.empty? ? nil : options[:url],
  mode: options[:mode],
  out: options[:out],
  use_cache: options[:use_cache],
  cache_dir: options[:cache_dir]
).run
