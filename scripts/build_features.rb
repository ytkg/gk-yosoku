#!/usr/bin/env ruby
# frozen_string_literal: true

require "csv"
require "date"
require "digest"
require "fileutils"
require "optparse"

class FeatureBuilder
  INPUT_HEADERS = %w[
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

  OUTPUT_HEADERS = %w[
    race_id
    race_date
    venue
    race_number
    racedetail_id
    player_name
    car_number
    rank
    top1
    top3
    hist_races
    hist_win_rate
    hist_top3_rate
    hist_avg_rank
    hist_last_rank
    hist_recent5_weighted_avg_rank
    hist_recent5_win_rate
    hist_recent5_top3_rate
    hist_days_since_last
    race_rel_hist_win_rate_rank
    race_rel_hist_top3_rate_rank
    mark_symbol
    leg_style
    odds_2shatan_min_first
    race_rel_odds_2shatan_rank
    race_field_size
  ].freeze

  def initialize(from_date:, to_date:, in_dir:, out_dir:, raw_html_dir:)
    @from_date = Date.iso8601(from_date)
    @to_date = Date.iso8601(to_date)
    raise ArgumentError, "from_date must be <= to_date" if @from_date > @to_date

    @in_dir = in_dir
    @out_dir = out_dir
    @results_html_dir = File.join(raw_html_dir, "results")
    @player_stats = {}
    @race_cache_context = {}
    FileUtils.mkdir_p(@out_dir)
  end

  def run
    (@from_date..@to_date).each do |date|
      rows = read_results(date)
      features = build_rows_for_date(rows, date)
      write_features(date, features)
      warn "date=#{date} input=#{rows.size} features=#{features.size}"
    end
  end

  private

  def read_results(date)
    path = File.join(@in_dir, "girls_results_#{date.strftime('%Y%m%d')}.csv")
    raise "not found: #{path}" unless File.exist?(path)

    CSV.read(path, headers: true, encoding: "UTF-8").map do |row|
      h = row.to_h
      missing = INPUT_HEADERS.reject { |k| h.key?(k) || k == "result_status" }
      raise "invalid headers in #{path}: missing #{missing.join(',')}" unless missing.empty?
      h["result_status"] = "normal" if h["result_status"].nil? || h["result_status"].empty?
      h
    end
  end

  def build_rows_for_date(rows, date)
    normal_rows = rows.select { |r| r["result_status"] == "normal" && r["rank"].to_s.match?(/\A[1-7]\z/) }
    races = normal_rows.group_by { |r| race_id_from_row(r) }

    features = []

    races.sort_by { |race_id, _| race_sort_key(race_id) }.each do |_race_id, race_rows|
      field_size = race_rows.size
      race_context = cache_context_for_race(date, race_rows.first)
      prepared = race_rows.map do |r|
        stats = stats_for(r["player_name"])
        car_no = r["car_number"].to_i
        cache = race_context[car_no] || {}
        {
          row: r,
          stats: stats,
          hist_win_rate_f: rate(stats[:win_count], stats[:count]),
          hist_top3_rate_f: rate(stats[:top3_count], stats[:count]),
          mark_symbol: cache[:mark_symbol] || mark_from_raw_cells(r["raw_cells"]),
          leg_style: cache[:leg_style].to_s,
          odds_2shatan_min_first_f: cache[:odds_2shatan_min_first] || 9999.9
        }
      end
      win_rate_rank = race_rank_map(prepared, :hist_win_rate_f)
      top3_rate_rank = race_rank_map(prepared, :hist_top3_rate_f)
      odds_rank = race_rank_map(prepared, :odds_2shatan_min_first_f, ascending: true)

      prepared.each do |p|
        r = p[:row]
        stats = p[:stats]
        rank = r["rank"].to_i

        features << {
          "race_id" => race_id_from_row(r),
          "race_date" => r["race_date"],
          "venue" => r["venue"],
          "race_number" => r["race_number"].to_i.to_s,
          "racedetail_id" => r["racedetail_id"],
          "player_name" => r["player_name"],
          "car_number" => r["car_number"].to_i.to_s,
          "rank" => rank.to_s,
          "top1" => rank == 1 ? "1" : "0",
          "top3" => rank <= 3 ? "1" : "0",
          "hist_races" => stats[:count].to_s,
          "hist_win_rate" => ratio(stats[:win_count], stats[:count]),
          "hist_top3_rate" => ratio(stats[:top3_count], stats[:count]),
          "hist_avg_rank" => avg_rank(stats),
          "hist_last_rank" => stats[:last_rank].to_s,
          "hist_recent5_weighted_avg_rank" => recent_weighted_avg_rank(stats, 5),
          "hist_recent5_win_rate" => recent_rate(stats, 1, 5),
          "hist_recent5_top3_rate" => recent_rate(stats, 3, 5),
          "hist_days_since_last" => days_since_last(stats, date).to_s,
          "race_rel_hist_win_rate_rank" => win_rate_rank[r["car_number"].to_i].to_s,
          "race_rel_hist_top3_rate_rank" => top3_rate_rank[r["car_number"].to_i].to_s,
          "mark_symbol" => p[:mark_symbol],
          "leg_style" => p[:leg_style],
          "odds_2shatan_min_first" => format("%.6f", p[:odds_2shatan_min_first_f]),
          "race_rel_odds_2shatan_rank" => odds_rank[r["car_number"].to_i].to_s,
          "race_field_size" => field_size.to_s
        }
      end

      race_rows.each do |r|
        update_stats(r["player_name"], r["rank"].to_i, date)
      end
    end

    deduped = features.uniq { |r| [r["race_id"], r["car_number"]] }
    deduped.sort_by { |r| [r["race_date"], r["venue"], r["race_number"].to_i, r["rank"].to_i] }
  end

  def race_id_from_row(row)
    "#{row['race_date']}-#{row['venue']}-#{format('%02d', row['race_number'].to_i)}"
  end

  def race_sort_key(race_id)
    date, venue, race_no = race_id.split("-", 3)
    [date, venue, race_no.to_i]
  end

  def stats_for(player_name)
    @player_stats[player_name] ||= {
      count: 0,
      win_count: 0,
      top3_count: 0,
      rank_sum: 0,
      last_rank: 0,
      last_date: nil,
      recent_ranks: []
    }
  end

  def update_stats(player_name, rank, date)
    st = stats_for(player_name)
    st[:count] += 1
    st[:win_count] += 1 if rank == 1
    st[:top3_count] += 1 if rank <= 3
    st[:rank_sum] += rank
    st[:last_rank] = rank
    st[:last_date] = date
    st[:recent_ranks].unshift(rank)
    st[:recent_ranks] = st[:recent_ranks].first(10)
  end

  def ratio(num, den)
    return "0.0" if den.zero?

    format("%.6f", num.to_f / den)
  end

  def avg_rank(stats)
    return "0.0" if stats[:count].zero?

    format("%.6f", stats[:rank_sum].to_f / stats[:count])
  end

  def recent_weighted_avg_rank(stats, window)
    recent = stats[:recent_ranks].first(window)
    return "0.0" if recent.empty?

    # Newer races get larger weights.
    weights = recent.each_index.map { |i| window - i }
    weighted_sum = recent.zip(weights).sum { |rank, w| rank * w }
    format("%.6f", weighted_sum.to_f / weights.sum)
  end

  def recent_rate(stats, threshold_rank, window)
    recent = stats[:recent_ranks].first(window)
    return "0.0" if recent.empty?

    hit = recent.count { |rank| rank <= threshold_rank }
    format("%.6f", hit.to_f / recent.size)
  end

  def race_rank_map(prepared_rows, key, ascending: false)
    sorted =
      if ascending
        prepared_rows.sort_by { |p| [p[key], p[:row]["car_number"].to_i] }
      else
        prepared_rows.sort_by { |p| [-p[key], p[:row]["car_number"].to_i] }
      end
    sorted.each_with_index.each_with_object({}) do |(p, idx), h|
      h[p[:row]["car_number"].to_i] = idx + 1
    end
  end

  def cache_context_for_race(date, race_row)
    key = race_row["show_result_url"].to_s
    return {} if key.empty?
    return @race_cache_context[key] if @race_cache_context.key?(key)

    path = File.join(@results_html_dir, date.strftime("%Y%m%d"), "result_#{Digest::SHA1.hexdigest(key)}.html")
    return @race_cache_context[key] = {} unless File.exist?(path)

    html = File.read(path, encoding: "UTF-8")
    @race_cache_context[key] = parse_race_cache(html)
  rescue StandardError
    @race_cache_context[key] = {}
  end

  def parse_race_cache(html)
    context = {}
    parse_tip_style_table(html).each { |car_no, attrs| context[car_no] = attrs }
    parse_2shatan_odds(html).each do |car_no, min_odd|
      context[car_no] ||= {}
      context[car_no][:odds_2shatan_min_first] = min_odd
    end
    context
  end

  def parse_tip_style_table(html)
    out = {}
    table = html.scan(/<table class="racecard_table[^"]*">(.*?)<\/table>/m)
                .map(&:first)
                .find { |t| t.include?("脚<br>質") && t.include?('class="num"') }
    return out if table.nil?

    table.scan(/<tr class="n\d+[^"]*">(.*?)<\/tr>/m).flatten.each do |tr|
      car_no = tr.match(/<td class="num"><span>(\d+)<\/span><\/td>/m)&.[](1).to_i
      next if car_no.zero?

      mark_symbol = tr.match(/icon_t\d+">([^<]+)</m)&.[](1).to_s.strip
      leg_style = tr.match(/<td class="bdr_r">\s*(逃|両|追)\s*<\/td>/m)&.[](1).to_s.strip
      out[car_no] = { mark_symbol: mark_symbol, leg_style: leg_style }
    end
    out
  end

  def parse_2shatan_odds(html)
    section = html.match(/<div class="odds_contents[^"]*" id="JS_ODDSCONTENTS_2shatan">(.*?)<!-- 2車単 End -->/m)&.[](1)
    return {} if section.nil?

    table = section.match(/<table class="odds_table">(.*?)<\/table>/m)&.[](1)
    return {} if table.nil?

    min_by_first = {}
    table.scan(/<tr>(.*?)<\/tr>/m).flatten.each do |tr|
      first_car = tr.match(/<th class="n\d+">(\d+)<\/th>/)&.[](1).to_i
      next if first_car.zero?

      cells = tr.scan(/<td[^>]*>(.*?)<\/td>/m).flatten
      next if cells.empty?

      odds_values = cells.map { |c| parse_odds_value(c) }.compact
      next if odds_values.empty?

      min_by_first[first_car] = odds_values.min
    end
    min_by_first
  end

  def parse_odds_value(cell_html)
    text = cell_html.to_s.gsub(/<[^>]+>/, " ").gsub(/\s+/, " ").strip
    return nil if text.empty? || text == "-"

    m = text.match(/(\d+(?:\.\d+)?)/)
    return nil if m.nil?

    m[1].to_f
  end

  def mark_from_raw_cells(raw_cells)
    token = raw_cells.to_s.split("|").first.to_s.strip
    return token if token.match?(/\A[◎○▲△×注]\z/)

    ""
  end

  def days_since_last(stats, current_date)
    return -1 if stats[:last_date].nil?

    (current_date - stats[:last_date]).to_i
  end

  def rate(num, den)
    return 0.0 if den.zero?

    num.to_f / den
  end

  def write_features(date, rows)
    path = File.join(@out_dir, "features_#{date.strftime('%Y%m%d')}.csv")
    CSV.open(path, "w", write_headers: true, headers: OUTPUT_HEADERS) do |csv|
      rows.each { |r| csv << OUTPUT_HEADERS.map { |h| r[h] } }
    end
  end
end

options = {
  from_date: Date.today.iso8601,
  to_date: Date.today.iso8601,
  in_dir: File.join("data", "raw"),
  out_dir: File.join("data", "features"),
  raw_html_dir: File.join("data", "raw_html")
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: ruby scripts/build_features.rb --from-date YYYY-MM-DD --to-date YYYY-MM-DD"
  opts.on("--from-date DATE", "開始日 (YYYY-MM-DD)") { |v| options[:from_date] = v }
  opts.on("--to-date DATE", "終了日 (YYYY-MM-DD)") { |v| options[:to_date] = v }
  opts.on("--in-dir DIR", "girls_results CSVの場所") { |v| options[:in_dir] = v }
  opts.on("--out-dir DIR", "features CSV出力先") { |v| options[:out_dir] = v }
  opts.on("--raw-html-dir DIR", "result HTMLキャッシュの場所") { |v| options[:raw_html_dir] = v }
end
parser.parse!

FeatureBuilder.new(
  from_date: options[:from_date],
  to_date: options[:to_date],
  in_dir: options[:in_dir],
  out_dir: options[:out_dir],
  raw_html_dir: options[:raw_html_dir]
).run
