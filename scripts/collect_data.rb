#!/usr/bin/env ruby
# frozen_string_literal: true

require "csv"
require "date"
require "digest"
require "fileutils"
require "net/http"
require "optparse"
require "uri"
require_relative "lib/html_utils"

class DataCollector
  RACES_HEADERS = %w[
    race_date
    venue
    race_number
    show_result_url
    racedetail_id
    kaisai_start_date
    kaisai_day_no
  ].freeze

  RESULTS_HEADERS = %w[
    race_date
    venue
    race_number
    racedetail_id
    show_result_url
    rank
    result_status
    frame_number
    car_number
    player_name
    age
    class
    raw_cells
  ].freeze

  ERRORS_HEADERS = %w[
    date
    level
    stage
    venue
    race_number
    racedetail_id
    url
    error_class
    error_message
    details
  ].freeze

  def initialize(from_date:, to_date:, raw_dir:, raw_html_dir:, use_cache:, sleep_sec:, max_retries:, retry_base_sleep:, kaisai_url_template:)
    @from_date = Date.iso8601(from_date)
    @to_date = Date.iso8601(to_date)
    raise ArgumentError, "from_date must be <= to_date" if @from_date > @to_date

    @raw_dir = raw_dir
    @raw_html_dir = raw_html_dir
    @results_html_dir = File.join(raw_html_dir, "results")
    @use_cache = use_cache
    @sleep_sec = sleep_sec
    @max_retries = max_retries
    @retry_base_sleep = retry_base_sleep
    @kaisai_url_template = kaisai_url_template
    raise ArgumentError, "max_retries must be >= 0" if @max_retries.negative?
    raise ArgumentError, "retry_base_sleep must be >= 0" if @retry_base_sleep.negative?
    @errors_by_date = Hash.new { |h, k| h[k] = [] }
    FileUtils.mkdir_p(@raw_dir)
    FileUtils.mkdir_p(@raw_html_dir)
    FileUtils.mkdir_p(@results_html_dir)
  end

  def run
    (@from_date..@to_date).each_with_index do |date, idx|
      sleep(@sleep_sec) if idx.positive? && @sleep_sec.positive?
      begin
        kaisai_html = fetch_kaisai_html(date)
      rescue StandardError => e
        record_error(
          date: date,
          level: "error",
          stage: "fetch_kaisai_html",
          url: kaisai_url_for(date),
          error: e
        )
        write_races_csv(date, [])
        write_results_csv(date, [])
        write_errors_csv(date)
        warn "date=#{date} races=0"
        warn "date=#{date} result_rows=0"
        warn "date=#{date} errors=#{@errors_by_date[date].size}"
        next
      end

      races = extract_girls_races(kaisai_html, date)
      validate_races!(date, races)
      write_races_csv(date, races)
      warn "date=#{date} races=#{races.size}"

      results = collect_results_for_races(date, races)
      validate_results!(date, results)
      write_results_csv(date, results)
      warn "date=#{date} result_rows=#{results.size}"
      write_errors_csv(date)
      warn "date=#{date} errors=#{@errors_by_date[date].size}"
    end
  end

  private

  def fetch_kaisai_html(date)
    path = File.join(@raw_html_dir, "kaisai_#{date.strftime('%Y%m%d')}.html")
    return File.read(path, encoding: "UTF-8") if @use_cache && File.exist?(path)

    url = kaisai_url_for(date)
    html = http_get(url, "gk-yosoku-collector/1.0")
    File.write(path, html)
    html
  end

  def kaisai_url_for(date)
    @kaisai_url_template % {
      date_yyyy: date.strftime("%Y"),
      date_mm: date.strftime("%m"),
      date_dd: date.strftime("%d")
    }
  end

  def fetch_result_html(date, url)
    day_dir = File.join(@results_html_dir, date.strftime("%Y%m%d"))
    FileUtils.mkdir_p(day_dir)
    path = File.join(day_dir, "result_#{Digest::SHA1.hexdigest(url)}.html")
    return File.read(path, encoding: "UTF-8") if @use_cache && File.exist?(path)

    html = http_get(url, "gk-yosoku-result-collector/1.0")
    File.write(path, html)
    html
  end

  def http_get(url, user_agent)
    attempt = 0
    begin
      attempt += 1
      uri = URI.parse(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 10
      http.read_timeout = 20

      req = Net::HTTP::Get.new(uri.request_uri)
      req["User-Agent"] = user_agent
      req["Accept"] = "text/html,application/xhtml+xml"
      res = http.request(req)
      raise "HTTP #{res.code}: #{url}" unless res.code.to_i == 200

      GK::HtmlUtils.normalize_body(res.body, res["content-type"])
    rescue StandardError
      raise if attempt > @max_retries

      sleep(@retry_base_sleep * (2**(attempt - 1))) if @retry_base_sleep.positive?
      retry
    end
  end

  def extract_girls_races(html, target_date)
    chunks = html.split(/<div class="kaisai-list" id="k\d+">/).drop(1)
    rows = []

    chunks.each do |chunk|
      tables = chunk.scan(/<div class="kaisai-program_table[^"]*">\s*<table>(.*?)<\/table>/m).map(&:first)
      tables.each do |table|
        tr_rows = table.scan(/<tr>(.*?)<\/tr>/m).map(&:first)
        tr_rows.each_with_index do |tr, i|
          next unless tr.include?("program_bg_7")

          girls_race_numbers = extract_girls_race_numbers(tr)
          next if girls_race_numbers.empty?

          link_row = tr_rows[(i + 1)..].find { |r| r.include?("pageType=showResult") }
          next unless link_row

          links = link_row.scan(%r{(https://keirin\.kdreams\.jp/([^/]+)/racedetail/(\d{16})/\?pageType=showResult)})
          next if links.empty?

          girls_race_numbers.each do |race_no|
            next if race_no > links.size

            show_result_url, venue, racedetail_id = links[race_no - 1]
            md = racedetail_id.match(/^\d{2}(\d{8})(\d{2})\d{4}$/)
            next if md.nil?

            start_date = Date.strptime(md[1], "%Y%m%d")
            day_no = md[2].to_i
            actual_date = start_date + (day_no - 1)
            next unless actual_date == target_date

            rows << {
              "race_date" => actual_date.iso8601,
              "venue" => venue,
              "race_number" => race_no.to_s,
              "show_result_url" => show_result_url,
              "racedetail_id" => racedetail_id,
              "kaisai_start_date" => start_date.iso8601,
              "kaisai_day_no" => day_no.to_s
            }
          end
        end
      end
    end

    rows.uniq { |r| [r["venue"], r["race_number"], r["show_result_url"]] }
        .sort_by { |r| [r["venue"], r["race_number"].to_i] }
  end

  def extract_girls_race_numbers(girls_row)
    race_numbers = []
    col = 1

    girls_row.scan(/<td([^>]*)>/i).each do |attr_match|
      attrs = attr_match[0]
      span = (attrs[/colspan="(\d+)"/i, 1] || "1").to_i
      klass = attrs[/class="([^"]+)"/i, 1].to_s
      race_numbers.concat((col...(col + span)).to_a) if klass.include?("program_bg_7")
      col += span
    end

    race_numbers
  end

  def collect_results_for_races(date, races)
    rows = []
    races.each_with_index do |race, idx|
      sleep(@sleep_sec) if idx.positive? && @sleep_sec.positive?
      begin
        html = fetch_result_html(date, race["show_result_url"])
        parsed_rows = parse_result_rows(race, html)
        if parsed_rows.empty?
          record_error(
            date: date,
            level: "warn",
            stage: "parse_result_rows_empty",
            race: race,
            url: race["show_result_url"],
            details: "result_tableが見つからない、または有効行が0件"
          )
        end
        rows.concat(parsed_rows)
      rescue StandardError => e
        record_error(
          date: date,
          level: "error",
          stage: "fetch_or_parse_result_html",
          race: race,
          url: race["show_result_url"],
          error: e
        )
      end
    end
    rows
  end

  def parse_result_rows(race, html)
    table_html = extract_result_table(html)
    return [] if table_html.nil?

    tr_htmls = table_html.scan(/<tr[^>]*>(.*?)<\/tr>/im).flatten
    parsed = tr_htmls.map { |tr| parse_result_row(tr) }.compact

    parsed.map do |entry|
      {
        "race_date" => race["race_date"],
        "venue" => race["venue"],
        "race_number" => race["race_number"],
        "racedetail_id" => race["racedetail_id"],
        "show_result_url" => race["show_result_url"],
        "rank" => entry["rank"],
        "result_status" => entry["result_status"],
        "frame_number" => "",
        "car_number" => entry["car_number"],
        "player_name" => entry["player_name"],
        "age" => "",
        "class" => "",
        "raw_cells" => entry["raw_cells"]
      }
    end
  end

  def extract_result_table(html)
    m = html.match(/<table class="result_table">(.*?)<\/table>/im)
    return nil if m.nil?

    m[1]
  end

  def parse_result_row(tr_html)
    cells = tr_html.scan(/<td[^>]*>(.*?)<\/td>/im).flatten
    return nil if cells.empty?

    clean = cells.map { |c| GK::HtmlUtils.normalize_text(c) }
    rank = clean[1].to_s
    result_status = classify_result_status(rank)
    return nil if result_status == "unknown"

    car_number = clean[2].to_s
    player_name = clean[3].to_s
    return nil if car_number.empty? || player_name.empty?

    {
      "rank" => rank,
      "result_status" => result_status,
      "car_number" => car_number,
      "player_name" => player_name,
      "raw_cells" => clean.join(" | ")
    }
  end

  def classify_result_status(rank_text)
    return "normal" if rank_text.match?(/\A[1-7]\z/)
    return "dq" if rank_text.include?("失")
    return "fall" if rank_text.include?("落")
    return "dns" if rank_text.include?("欠")
    return "dnf" if rank_text.match?(/[棄故再]/)

    "unknown"
  end

  def validate_races!(date, rows)
    seen = {}
    rows.each do |r|
      key = [r["venue"], r["race_number"], r["racedetail_id"]].join("-")
      unless seen[key].nil?
        record_error(
          date: date,
          level: "warn",
          stage: "validate_races_duplicate",
          race: r,
          url: r["show_result_url"],
          details: "duplicate race key=#{key}"
        )
      end

      seen[key] = true
    end
  end

  def validate_results!(date, rows)
    grouped = rows.group_by { |r| [r["venue"], r["race_number"], r["racedetail_id"]] }
    grouped.each do |(venue, race_number, racedetail_id), race_rows|
      if race_rows.size != 7
        record_error(
          date: date,
          level: "warn",
          stage: "validate_results_count",
          race: {
            "venue" => venue,
            "race_number" => race_number,
            "racedetail_id" => racedetail_id,
            "show_result_url" => race_rows.first["show_result_url"]
          },
          details: "rows=#{race_rows.size} (girlsは通常7車)"
        )
      end

      cars = race_rows.map { |r| r["car_number"].to_s }
      if cars.size != cars.uniq.size
        record_error(
          date: date,
          level: "warn",
          stage: "validate_results_duplicate_car",
          race: {
            "venue" => venue,
            "race_number" => race_number,
            "racedetail_id" => racedetail_id,
            "show_result_url" => race_rows.first["show_result_url"]
          },
          details: "car_number duplicate detected: #{cars.join(',')}"
        )
      end
    end
  end

  def record_error(date:, level:, stage:, race: nil, url: nil, error: nil, details: nil)
    @errors_by_date[date] << {
      "date" => date.iso8601,
      "level" => level.to_s,
      "stage" => stage.to_s,
      "venue" => race ? race["venue"].to_s : "",
      "race_number" => race ? race["race_number"].to_s : "",
      "racedetail_id" => race ? race["racedetail_id"].to_s : "",
      "url" => (url || (race && race["show_result_url"])).to_s,
      "error_class" => error ? error.class.to_s : "",
      "error_message" => error ? error.message.to_s : "",
      "details" => details.to_s
    }
  end

  def write_errors_csv(date)
    path = File.join(@raw_dir, "girls_errors_#{date.strftime('%Y%m%d')}.csv")
    rows = @errors_by_date[date] || []
    CSV.open(path, "w", write_headers: true, headers: ERRORS_HEADERS) do |csv|
      rows.each { |r| csv << ERRORS_HEADERS.map { |h| r[h] } }
    end
  end

  def write_races_csv(date, rows)
    path = File.join(@raw_dir, "girls_races_#{date.strftime('%Y%m%d')}.csv")
    CSV.open(path, "w", write_headers: true, headers: RACES_HEADERS) do |csv|
      rows.each { |r| csv << RACES_HEADERS.map { |h| r[h] } }
    end
  end

  def write_results_csv(date, rows)
    path = File.join(@raw_dir, "girls_results_#{date.strftime('%Y%m%d')}.csv")
    CSV.open(path, "w", write_headers: true, headers: RESULTS_HEADERS) do |csv|
      rows.each { |r| csv << RESULTS_HEADERS.map { |h| r[h] } }
    end
  end
end

options = {
  from_date: nil,
  to_date: nil,
  raw_dir: File.join("data", "raw"),
  raw_html_dir: File.join("data", "raw_html"),
  use_cache: true,
  sleep_sec: 0.5,
  max_retries: 3,
  retry_base_sleep: 0.5,
  kaisai_url_template: "https://keirin.kdreams.jp/kaisai/%{date_yyyy}/%{date_mm}/%{date_dd}/"
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: ruby scripts/collect_data.rb --from-date YYYY-MM-DD --to-date YYYY-MM-DD"
  opts.on("--from-date DATE", "開始日 (YYYY-MM-DD)") { |v| options[:from_date] = v }
  opts.on("--to-date DATE", "終了日 (YYYY-MM-DD)") { |v| options[:to_date] = v }
  opts.on("--raw-dir DIR", "CSV出力先（girls_races/girls_results）") { |v| options[:raw_dir] = v }
  opts.on("--raw-html-dir DIR", "HTMLキャッシュ保存先") { |v| options[:raw_html_dir] = v }
  opts.on("--[no-]cache", "保存済みHTMLを使う（既定: true）") { |v| options[:use_cache] = v }
  opts.on("--sleep SEC", Float, "アクセス間隔秒（既定: 0.5）") { |v| options[:sleep_sec] = v }
  opts.on("--max-retries N", Integer, "HTTPリトライ回数（既定: 3）") { |v| options[:max_retries] = v }
  opts.on("--retry-base-sleep SEC", Float, "HTTPリトライ基準待機秒（既定: 0.5）") { |v| options[:retry_base_sleep] = v }
  opts.on("--kaisai-url-template TEMPLATE", "開催ページURLテンプレート（既定: Kドリームズ）") { |v| options[:kaisai_url_template] = v }
end
parser.parse!

if options[:from_date].nil? || options[:to_date].nil?
  warn parser.to_s
  exit 1
end

DataCollector.new(
  from_date: options[:from_date],
  to_date: options[:to_date],
  raw_dir: options[:raw_dir],
  raw_html_dir: options[:raw_html_dir],
  use_cache: options[:use_cache],
  sleep_sec: options[:sleep_sec],
  max_retries: options[:max_retries],
  retry_base_sleep: options[:retry_base_sleep],
  kaisai_url_template: options[:kaisai_url_template]
).run
