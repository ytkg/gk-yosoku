#!/usr/bin/env ruby
# frozen_string_literal: true

require "csv"
require "date"
require "digest"
require "fileutils"
require "json"
require "net/http"
require "nkf"
require "open3"
require "optparse"
require "tmpdir"
require "uri"

class RacePredictor
  CATEGORICAL_FEATURES = %w[venue player_name mark_symbol leg_style].freeze
  NUMERIC_FEATURES = %w[
    race_number
    car_number
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
    odds_2shatan_min_first
    race_rel_odds_2shatan_rank
    race_field_size
  ].freeze
  FEATURE_COLUMNS = (CATEGORICAL_FEATURES + NUMERIC_FEATURES).freeze

  def initialize(url:, model_top3:, encoders_top3:, model_top1:, encoders_top1:, raw_dir:, cache_dir:, win_temperature:, exacta_top:, trifecta_top:, use_cache:)
    @url = url
    @model_top3 = model_top3
    @encoders_top3 = encoders_top3
    @model_top1 = model_top1
    @encoders_top1 = encoders_top1
    @raw_dir = raw_dir
    @cache_dir = cache_dir
    @win_temperature = win_temperature
    @exacta_top = exacta_top
    @trifecta_top = trifecta_top
    @use_cache = use_cache
    FileUtils.mkdir_p(@cache_dir)
  end

  def run
    check_lightgbm!
    race = parse_race_meta(@url)
    html = fetch_html(@url)
    entries = parse_entries(html)
    raise "entry parse failed: #{@url}" if entries.empty?

    odds_by_first = parse_2shatan_odds(html)
    entries.each do |e|
      e[:odds_2shatan_min_first] = odds_by_first[e[:car_number]] || 9999.9
    end

    stats = load_player_stats(race[:race_date])
    feature_rows = build_feature_rows(entries, race, stats)

    pred_top3 = predict_scores(feature_rows, @model_top3, @encoders_top3)
    pred_top1 = predict_scores(feature_rows, @model_top1, @encoders_top1)
    merged = feature_rows.each_with_index.map do |r, i|
      r.merge(
        "score_top3" => pred_top3[i],
        "score_top1" => pred_top1[i]
      )
    end

    print_rankings(race, merged)
    print_exotics(race, merged)
  end

  private

  def parse_race_meta(url)
    uri = URI.parse(url)
    md = uri.path.match(%r{^/([^/]+)/racedetail/(\d{16})/?$})
    raise "invalid race url: #{url}" if md.nil?

    venue = md[1]
    racedetail_id = md[2]
    m2 = racedetail_id.match(/^\d{2}(\d{8})(\d{2})\d{2}(\d{2})$/)
    raise "invalid racedetail_id: #{racedetail_id}" if m2.nil?

    start_date = Date.strptime(m2[1], "%Y%m%d")
    day_no = m2[2].to_i
    race_number = m2[3].to_i
    {
      race_id: "#{(start_date + (day_no - 1)).iso8601}-#{venue}-#{format('%02d', race_number)}",
      race_date: start_date + (day_no - 1),
      venue: venue,
      race_number: race_number,
      racedetail_id: racedetail_id
    }
  end

  def fetch_html(url)
    path = File.join(@cache_dir, "race_#{Digest::SHA1.hexdigest(url)}.html")
    return File.read(path, encoding: "UTF-8") if @use_cache && File.exist?(path)

    uri = URI.parse(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 10
    http.read_timeout = 20
    req = Net::HTTP::Get.new(uri.request_uri)
    req["User-Agent"] = "gk-yosoku-predictor/1.0"
    req["Accept"] = "text/html,application/xhtml+xml"
    res = http.request(req)
    raise "HTTP #{res.code}: #{url}" unless res.code.to_i == 200

    html = normalize_body(res.body, res["content-type"])
    File.write(path, html)
    html
  end

  def normalize_body(body, content_type)
    raw = body.dup
    charset = content_type.to_s[/charset=([^\s;]+)/i, 1]
    enc = begin
      charset ? Encoding.find(charset) : NKF.guess(raw)
    rescue StandardError
      Encoding::UTF_8
    end
    raw.force_encoding(enc)
    raw.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
  end

  def parse_entries(html)
    table = html.scan(/<table class="racecard_table[^"]*">(.*?)<\/table>/m)
                .map(&:first)
                .find { |t| t.include?("脚<br>質") && t.include?('class="num"') }
    return [] if table.nil?

    table.scan(/<tr class="n\d+[^"]*">(.*?)<\/tr>/m).flatten.map do |tr|
      car = tr.match(/<td class="num"><span>(\d+)<\/span><\/td>/m)&.[](1).to_i
      next if car.zero?
      player_name = normalize_text(tr.match(/<td class="rider bdr_r">(.*?)<\/td>/m)&.[](1).to_s.split("<br>").first)
      mark_symbol = tr.match(/icon_t\d+">([^<]+)</m)&.[](1).to_s.strip
      leg_style = tr.match(/<td class="bdr_r">\s*(逃|両|追)\s*<\/td>/m)&.[](1).to_s.strip
      {
        car_number: car,
        player_name: player_name,
        mark_symbol: mark_symbol,
        leg_style: leg_style
      }
    end.compact.sort_by { |e| e[:car_number] }
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

      vals = tr.scan(/<td[^>]*>(.*?)<\/td>/m).flatten.map { |cell| parse_odds_value(cell) }.compact
      next if vals.empty?
      min_by_first[first_car] = vals.min
    end
    min_by_first
  end

  def parse_odds_value(cell_html)
    text = normalize_text(cell_html)
    return nil if text.empty? || text == "-"
    m = text.match(/(\d+(?:\.\d+)?)/)
    return nil if m.nil?
    m[1].to_f
  end

  def normalize_text(text)
    text.to_s
        .gsub(/<[^>]+>/, " ")
        .gsub(/&nbsp;/i, " ")
        .gsub(/&amp;/i, "&")
        .gsub(/\s+/, " ")
        .strip
  end

  def load_player_stats(target_date)
    stats = Hash.new do |h, k|
      h[k] = { count: 0, win_count: 0, top3_count: 0, rank_sum: 0, last_rank: 0, last_date: nil, recent_ranks: [] }
    end
    Dir.glob(File.join(@raw_dir, "girls_results_*.csv")).sort.each do |path|
      date = Date.strptime(path[/girls_results_(\d{8})\.csv/, 1], "%Y%m%d")
      next unless date < target_date

      rows = CSV.read(path, headers: true, encoding: "UTF-8").map(&:to_h)
      rows.each do |r|
        next unless r["result_status"] == "normal"
        rank = r["rank"].to_i
        next unless rank.between?(1, 7)
        name = r["player_name"].to_s
        st = stats[name]
        st[:count] += 1
        st[:win_count] += 1 if rank == 1
        st[:top3_count] += 1 if rank <= 3
        st[:rank_sum] += rank
        st[:last_rank] = rank
        st[:last_date] = date
        st[:recent_ranks].unshift(rank)
        st[:recent_ranks] = st[:recent_ranks].first(10)
      end
    end
    stats
  end

  def build_feature_rows(entries, race, stats)
    rows = entries.map do |e|
      st = stats[e[:player_name]]
      {
        "race_id" => race[:race_id],
        "race_date" => race[:race_date].iso8601,
        "venue" => race[:venue],
        "race_number" => race[:race_number].to_s,
        "racedetail_id" => race[:racedetail_id],
        "player_name" => e[:player_name],
        "car_number" => e[:car_number].to_s,
        "mark_symbol" => e[:mark_symbol].to_s,
        "leg_style" => e[:leg_style].to_s,
        "hist_races" => st[:count].to_s,
        "hist_win_rate" => ratio(st[:win_count], st[:count]),
        "hist_top3_rate" => ratio(st[:top3_count], st[:count]),
        "hist_avg_rank" => avg_rank(st),
        "hist_last_rank" => st[:last_rank].to_s,
        "hist_recent5_weighted_avg_rank" => recent_weighted_avg_rank(st, 5),
        "hist_recent5_win_rate" => recent_rate(st, 1, 5),
        "hist_recent5_top3_rate" => recent_rate(st, 3, 5),
        "hist_days_since_last" => days_since_last(st, race[:race_date]).to_s,
        "odds_2shatan_min_first" => format("%.6f", e[:odds_2shatan_min_first].to_f),
        "race_field_size" => entries.size.to_s
      }
    end

    enrich_relative_ranks!(rows)
    rows
  end

  def enrich_relative_ranks!(rows)
    win_sorted = rows.sort_by { |r| [-r["hist_win_rate"].to_f, r["car_number"].to_i] }
    top3_sorted = rows.sort_by { |r| [-r["hist_top3_rate"].to_f, r["car_number"].to_i] }
    odds_sorted = rows.sort_by { |r| [r["odds_2shatan_min_first"].to_f, r["car_number"].to_i] }
    win_rank = win_sorted.each_with_index.to_h { |r, i| [r["car_number"], i + 1] }
    top3_rank = top3_sorted.each_with_index.to_h { |r, i| [r["car_number"], i + 1] }
    odds_rank = odds_sorted.each_with_index.to_h { |r, i| [r["car_number"], i + 1] }

    rows.each do |r|
      r["race_rel_hist_win_rate_rank"] = win_rank[r["car_number"]].to_s
      r["race_rel_hist_top3_rate_rank"] = top3_rank[r["car_number"]].to_s
      r["race_rel_odds_2shatan_rank"] = odds_rank[r["car_number"]].to_s
    end
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
    weights = recent.each_index.map { |i| window - i }
    format("%.6f", recent.zip(weights).sum { |rank, w| rank * w }.to_f / weights.sum)
  end

  def recent_rate(stats, threshold_rank, window)
    recent = stats[:recent_ranks].first(window)
    return "0.0" if recent.empty?
    format("%.6f", recent.count { |rank| rank <= threshold_rank }.to_f / recent.size)
  end

  def days_since_last(stats, current_date)
    return -1 if stats[:last_date].nil?
    (current_date - stats[:last_date]).to_i
  end

  def check_lightgbm!
    return if system("command -v lightgbm >/dev/null 2>&1")
    raise "lightgbm command not found"
  end

  def predict_scores(rows, model_path, encoders_path)
    encoders = JSON.parse(File.read(encoders_path, encoding: "UTF-8"))
    Dir.mktmpdir("gk-predict-") do |tmp|
      data_tsv = File.join(tmp, "data.tsv")
      pred_txt = File.join(tmp, "pred.txt")
      conf = File.join(tmp, "predict.conf")

      File.open(data_tsv, "w") do |f|
        rows.each do |r|
          xs = FEATURE_COLUMNS.map do |name|
            if CATEGORICAL_FEATURES.include?(name)
              (encoders.fetch(name, {})[r[name].to_s] || -1).to_s
            else
              r[name].to_f.to_s
            end
          end
          f.puts((["0"] + xs).join("\t"))
        end
      end

      File.write(conf, <<~CONF)
        task=predict
        data=#{data_tsv}
        input_model=#{model_path}
        output_result=#{pred_txt}
        header=false
      CONF
      _out, err, status = Open3.capture3("lightgbm", "config=#{conf}")
      raise "lightgbm predict failed: #{err}" unless status.success?
      File.readlines(pred_txt, chomp: true).map(&:to_f)
    end
  end

  def print_rankings(race, rows)
    puts "# Race: #{race[:venue]} #{race[:race_date]} #{race[:race_number]}R (#{race[:racedetail_id]})"
    puts "## Top1 Probability Ranking"
    rows.sort_by { |r| -r["score_top1"] }.each_with_index do |r, idx|
      puts format("%2d. %s %s top1=%.6f top3=%.6f mark=%s style=%s", idx + 1, r["car_number"], r["player_name"], r["score_top1"], r["score_top3"], r["mark_symbol"], r["leg_style"])
    end
  end

  def print_exotics(_race, rows)
    cars = rows.map do |r|
      {
        car_number: r["car_number"].to_i,
        player_name: r["player_name"],
        top3_score: clamp01(r["score_top3"]),
        top1_score: r["score_top1"].to_f
      }
    end
    p_win = softmax_win(cars)
    exacta = []
    trifecta = []
    cars.each do |i|
      cars.each do |j|
        next if i[:car_number] == j[:car_number]
        exacta << [i, j, p_win[i[:car_number]] * j[:top3_score]]
        cars.each do |k|
          next if [i[:car_number], j[:car_number]].include?(k[:car_number])
          trifecta << [i, j, k, p_win[i[:car_number]] * j[:top3_score] * k[:top3_score]]
        end
      end
    end
    puts "## Exacta Top #{@exacta_top}"
    exacta.sort_by { |x| -x[2] }.first(@exacta_top).each_with_index do |(i, j, s), idx|
      puts format("%2d. %d-%d %.10f (%s-%s)", idx + 1, i[:car_number], j[:car_number], s, i[:player_name], j[:player_name])
    end
    puts "## Trifecta Top #{@trifecta_top}"
    trifecta.sort_by { |x| -x[3] }.first(@trifecta_top).each_with_index do |(i, j, k, s), idx|
      puts format("%2d. %d-%d-%d %.10f (%s-%s-%s)", idx + 1, i[:car_number], j[:car_number], k[:car_number], s, i[:player_name], j[:player_name], k[:player_name])
    end
  end

  def clamp01(v)
    x = v.to_f
    return 0.0 if x.nan? || x.negative?
    return 1.0 if x > 1.0
    x
  end

  def softmax_win(cars)
    exps = cars.to_h { |c| [c[:car_number], Math.exp(c[:top1_score] / @win_temperature)] }
    sum = exps.values.sum
    exps.transform_values { |v| v / sum }
  end
end

options = {
  url: nil,
  model_top3: File.join("data", "ml", "model.txt"),
  encoders_top3: File.join("data", "ml", "encoders.json"),
  model_top1: File.join("data", "ml_top1", "model.txt"),
  encoders_top1: File.join("data", "ml_top1", "encoders.json"),
  raw_dir: File.join("data", "raw"),
  cache_dir: File.join("data", "raw_html", "predict"),
  win_temperature: 0.15,
  exacta_top: 10,
  trifecta_top: 20,
  use_cache: true
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: ruby scripts/predict_race.rb --url https://keirin.kdreams.jp/.../racedetail/xxxxxxxxxxxxxxxx/"
  opts.on("--url URL", "race detail url") { |v| options[:url] = v }
  opts.on("--model-top3 PATH", "top3 model path") { |v| options[:model_top3] = v }
  opts.on("--encoders-top3 PATH", "top3 encoders path") { |v| options[:encoders_top3] = v }
  opts.on("--model-top1 PATH", "top1 model path") { |v| options[:model_top1] = v }
  opts.on("--encoders-top1 PATH", "top1 encoders path") { |v| options[:encoders_top1] = v }
  opts.on("--raw-dir DIR", "history csv dir") { |v| options[:raw_dir] = v }
  opts.on("--cache-dir DIR", "html cache dir") { |v| options[:cache_dir] = v }
  opts.on("--win-temperature X", Float, "temperature for top1 softmax") { |v| options[:win_temperature] = v }
  opts.on("--exacta-top N", Integer, "exacta top N") { |v| options[:exacta_top] = v }
  opts.on("--trifecta-top N", Integer, "trifecta top N") { |v| options[:trifecta_top] = v }
  opts.on("--[no-]cache", "use cache html (default: true)") { |v| options[:use_cache] = v }
end
parser.parse!

if options[:url].to_s.empty?
  warn parser.to_s
  exit 1
end

RacePredictor.new(
  url: options[:url],
  model_top3: options[:model_top3],
  encoders_top3: options[:encoders_top3],
  model_top1: options[:model_top1],
  encoders_top1: options[:encoders_top1],
  raw_dir: options[:raw_dir],
  cache_dir: options[:cache_dir],
  win_temperature: options[:win_temperature],
  exacta_top: options[:exacta_top],
  trifecta_top: options[:trifecta_top],
  use_cache: options[:use_cache]
).run
