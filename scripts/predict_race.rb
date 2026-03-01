#!/usr/bin/env ruby
# frozen_string_literal: true

require "csv"
require "date"
require "digest"
require "fileutils"
require "json"
require "net/http"
require "open3"
require "optparse"
require "tmpdir"
require "uri"
require_relative "lib/exacta_feature_schema"
require_relative "lib/feature_schema"
require_relative "lib/exotic_scoring"
require_relative "lib/html_utils"
require_relative "lib/lightgbm_utils"
require_relative "lib/model_manifest"

class RacePredictor
  DEFAULT_WIN_PRIOR = (1.0 / 7.0)
  DEFAULT_TOP3_PRIOR = (3.0 / 7.0)
  PLAYER_PRIOR_STRENGTH = 18.0
  RECENT_PRIOR_STRENGTH = 5.0
  PAIR_PRIOR_STRENGTH = 8.0
  TRIPLET_PRIOR_STRENGTH = 8.0

  def initialize(url:, model_top3:, encoders_top3:, model_top1:, encoders_top1:, model_exacta:, encoders_exacta:, use_exacta_model:, raw_dir:, cache_dir:, win_temperature:, exacta_top:, trifecta_top:, use_cache:, no_bet_gap_threshold:, exacta_min_ev:, bankroll:, unit:, kelly_cap:, bet_style:, exotic_profile:, exacta_win_exp:, exacta_second_exp:, exacta_second_win_exp:, trifecta_win_exp:, trifecta_second_exp:, trifecta_third_exp:)
    @url = url
    @model_top3 = model_top3
    @encoders_top3 = encoders_top3
    @model_top1 = model_top1
    @encoders_top1 = encoders_top1
    @model_exacta = model_exacta
    @encoders_exacta = encoders_exacta
    @use_exacta_model = use_exacta_model
    @raw_dir = raw_dir
    @cache_dir = cache_dir
    @exotic_params = build_exotic_params(
      exotic_profile: exotic_profile,
      win_temperature: win_temperature,
      exacta_win_exp: exacta_win_exp,
      exacta_second_exp: exacta_second_exp,
      exacta_second_win_exp: exacta_second_win_exp,
      trifecta_win_exp: trifecta_win_exp,
      trifecta_second_exp: trifecta_second_exp,
      trifecta_third_exp: trifecta_third_exp
    )
    @win_temperature = @exotic_params.fetch("win_temperature")
    @exacta_top = exacta_top
    @trifecta_top = trifecta_top
    @use_cache = use_cache
    @no_bet_gap_threshold = no_bet_gap_threshold
    @exacta_min_ev = exacta_min_ev
    @bankroll = bankroll
    @unit = unit
    @kelly_cap = kelly_cap
    @bet_style = bet_style
    @feature_columns_top3 = load_feature_columns(@model_top3, GK::FeatureSchema::FEATURE_COLUMNS)
    @feature_columns_top1 = load_feature_columns(@model_top1, GK::FeatureSchema::FEATURE_COLUMNS)
    @feature_columns_exacta = load_feature_columns(@model_exacta, GK::ExactaFeatureSchema::FEATURE_COLUMNS)
    validate_model_manifest!(@model_top3, @feature_columns_top3)
    validate_model_manifest!(@model_top1, @feature_columns_top1)
    validate_model_manifest!(@model_exacta, @feature_columns_exacta)
    @same_meet_history = {}
    @pair_history = {}
    @triplet_history = {}
    @global_entries = 0
    @global_wins = 0
    @global_top3 = 0
    FileUtils.mkdir_p(@cache_dir)
  end

  def run
    check_lightgbm!
    race = parse_race_meta(@url)
    html = fetch_html(@url)
    entries = parse_entries(html)
    raise "entry parse failed: #{@url}" if entries.empty?

    odds_by_first = parse_2shatan_odds(html)
    pair_odds = parse_2shatan_pair_odds(html)
    trifecta_odds = parse_3rentan_odds(html)
    print_odds_source_note
    verify_odds_direction(html, pair_odds, trifecta_odds)
    entries.each do |e|
      e[:odds_2shatan_min_first] = odds_by_first[e[:car_number]] || 9999.9
    end

    stats = load_player_stats(race[:race_date])
    feature_rows = build_feature_rows(entries, race, stats)

    pred_top3 = predict_scores(feature_rows, @model_top3, @encoders_top3, @feature_columns_top3)
    pred_top1 = predict_scores(feature_rows, @model_top1, @encoders_top1, @feature_columns_top1)
    exacta_scores = predict_exacta_scores(feature_rows)
    merged = feature_rows.each_with_index.map do |r, i|
      r.merge(
        "score_top3" => pred_top3[i],
        "score_top1" => pred_top1[i]
      )
    end

    print_rankings(race, merged)
    print_exotics(race, merged, pair_odds, trifecta_odds, exacta_scores)
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
      start_date: start_date,
      day_number: day_no,
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

    html = GK::HtmlUtils.normalize_body(res.body, res["content-type"])
    File.write(path, html)
    html
  end

  def parse_entries(html)
    GK::HtmlUtils.parse_racecard_entries(html).map do |entry|
      {
        car_number: entry[:car_number],
        player_name: entry[:player_name],
        mark_symbol: entry[:mark_symbol],
        leg_style: entry[:leg_style]
      }
    end
  end

  def parse_2shatan_odds(html)
    GK::HtmlUtils.parse_2shatan_odds(html)
  end

  def parse_2shatan_pair_odds(html)
    GK::HtmlUtils.parse_2shatan_pair_odds(html)
  end

  def parse_3rentan_odds(html)
    GK::HtmlUtils.parse_3rentan_odds(html)
  end

  def load_player_stats(target_date)
    stats = Hash.new do |h, k|
      h[k] = { count: 0, win_count: 0, top3_count: 0, rank_sum: 0, last_rank: 0, last_date: nil, recent_ranks: [] }
    end
    @same_meet_history = Hash.new { |h, k| h[k] = { count: 0, rank_sum: 0, prev_day_rank: 0 } }
    @pair_history = Hash.new { |h, k| h[k] = { count: 0, both_top3_count: 0, top3_counts: Hash.new(0) } }
    @triplet_history = Hash.new { |h, k| h[k] = { count: 0, all_top3_count: 0, top3_counts: Hash.new(0) } }
    @global_entries = 0
    @global_wins = 0
    @global_top3 = 0
    Dir.glob(File.join(@raw_dir, "girls_results_*.csv")).sort.each do |path|
      date = Date.strptime(path[/girls_results_(\d{8})\.csv/, 1], "%Y%m%d")
      next unless date < target_date

      rows = CSV.read(path, headers: true, encoding: "UTF-8").map(&:to_h)
      normal_rows = rows.select do |r|
        r["result_status"] == "normal" && r["rank"].to_i.between?(1, 7)
      end
      races = normal_rows.group_by { |r| race_id_from_row(r) }
      races.each_value do |race_rows|
        race_rows.each do |r|
          rank = r["rank"].to_i
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
          update_same_meet_history(r, rank)
          update_global_history(rank)
        end
        update_pair_triplet_history(race_rows)
      end
    end
    stats
  end

  def build_feature_rows(entries, race, stats)
    global_win_prior = global_win_rate_prior
    global_top3_prior = global_top3_rate_prior

    rows = entries.map do |e|
      st = stats[e[:player_name]]
      hist_win_rate_f = smoothed_rate(st[:win_count], st[:count], global_win_prior, PLAYER_PRIOR_STRENGTH)
      hist_top3_rate_f = smoothed_rate(st[:top3_count], st[:count], global_top3_prior, PLAYER_PRIOR_STRENGTH)
      hist_recent3_win_rate_f = recent_rate_smoothed_f(st, 1, 3, hist_win_rate_f, RECENT_PRIOR_STRENGTH)
      hist_recent3_top3_rate_f = recent_rate_smoothed_f(st, 3, 3, hist_top3_rate_f, RECENT_PRIOR_STRENGTH)
      hist_recent5_win_rate_f = recent_rate_smoothed_f(st, 1, 5, hist_win_rate_f, RECENT_PRIOR_STRENGTH)
      hist_recent5_top3_rate_f = recent_rate_smoothed_f(st, 3, 5, hist_top3_rate_f, RECENT_PRIOR_STRENGTH)
      pair_ctx = pair_context(e[:player_name], entries, stats, hist_top3_rate_f, global_top3_prior)
      triplet_ctx = triplet_context(e[:player_name], entries, stats, hist_top3_rate_f, global_top3_prior)
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
        "hist_win_rate" => format("%.6f", hist_win_rate_f),
        "hist_top3_rate" => format("%.6f", hist_top3_rate_f),
        "hist_avg_rank" => avg_rank(st),
        "hist_last_rank" => st[:last_rank].to_s,
        "hist_recent3_weighted_avg_rank" => recent_weighted_avg_rank(st, 3),
        "hist_recent3_win_rate" => format("%.6f", hist_recent3_win_rate_f),
        "hist_recent3_top3_rate" => format("%.6f", hist_recent3_top3_rate_f),
        "recent3_vs_hist_top3_delta" => "0.0",
        "hist_recent5_weighted_avg_rank" => recent_weighted_avg_rank(st, 5),
        "hist_recent5_win_rate" => format("%.6f", hist_recent5_win_rate_f),
        "hist_recent5_top3_rate" => format("%.6f", hist_recent5_top3_rate_f),
        "hist_days_since_last" => days_since_last(st, race[:race_date]).to_s,
        "same_meet_day_number" => race[:day_number].to_s,
        "same_meet_prev_day_exists" => same_meet_prev_day_exists(race, e[:player_name]).to_s,
        "same_meet_prev_day_rank" => same_meet_prev_day_rank(race, e[:player_name]).to_s,
        "same_meet_prev_day_top1" => (same_meet_prev_day_rank(race, e[:player_name]) == 1 ? 1 : 0).to_s,
        "same_meet_prev_day_top3" => ((1..3).cover?(same_meet_prev_day_rank(race, e[:player_name])) ? 1 : 0).to_s,
        "same_meet_races" => same_meet_stats(race, e[:player_name])[:count].to_s,
        "same_meet_avg_rank" => format("%.6f", same_meet_avg_rank(race, e[:player_name])),
        "same_meet_prev_day_rank_inv" => "0.0",
        "same_meet_recent3_synergy" => "0.0",
        "pair_hist_count_total" => format("%.6f", pair_ctx[:count_total]),
        "pair_hist_i_top3_rate_avg" => format("%.6f", pair_ctx[:i_top3_rate_avg]),
        "pair_hist_both_top3_rate_avg" => format("%.6f", pair_ctx[:both_top3_rate_avg]),
        "triplet_hist_count_total" => format("%.6f", triplet_ctx[:count_total]),
        "triplet_hist_i_top3_rate_avg" => format("%.6f", triplet_ctx[:i_top3_rate_avg]),
        "triplet_hist_all_top3_rate_avg" => format("%.6f", triplet_ctx[:all_top3_rate_avg]),
        "mark_score" => format("%.1f", mark_score(e[:mark_symbol])),
        "odds_2shatan_min_first" => format("%.6f", e[:odds_2shatan_min_first].to_f),
        "race_field_size" => entries.size.to_s
      }
    end

    enrich_relative_ranks!(rows)
    rows
  end

  def enrich_relative_ranks!(rows)
    rows.each do |r|
      r["recent3_vs_hist_top3_delta"] = format("%.6f", r["hist_recent3_top3_rate"].to_f - r["hist_top3_rate"].to_f)
      rank = r["same_meet_prev_day_rank"].to_i
      inv = rank.positive? ? (1.0 / rank) : 0.0
      r["same_meet_prev_day_rank_inv"] = format("%.6f", inv)
      r["same_meet_recent3_synergy"] = format("%.6f", inv * r["hist_recent3_top3_rate"].to_f)
    end

    avg_rank_sorted = rows.sort_by { |r| [safe_avg_rank_sort_value(r["hist_avg_rank"]), r["car_number"].to_i] }
    recent3_top3_sorted = rows.sort_by { |r| [-r["hist_recent3_top3_rate"].to_f, r["car_number"].to_i] }
    recent5_top3_sorted = rows.sort_by { |r| [-r["hist_recent5_top3_rate"].to_f, r["car_number"].to_i] }
    same_meet_prev_day_sorted = rows.sort_by { |r| [safe_same_meet_rank(r["same_meet_prev_day_rank"]), r["car_number"].to_i] }
    same_meet_avg_sorted = rows.sort_by { |r| [safe_avg_rank_sort_value(r["same_meet_avg_rank"]), r["car_number"].to_i] }
    same_meet_recent3_synergy_sorted = rows.sort_by { |r| [-r["same_meet_recent3_synergy"].to_f, r["car_number"].to_i] }
    pair_i_top3_sorted = rows.sort_by { |r| [-r["pair_hist_i_top3_rate_avg"].to_f, r["car_number"].to_i] }
    triplet_i_top3_sorted = rows.sort_by { |r| [-r["triplet_hist_i_top3_rate_avg"].to_f, r["car_number"].to_i] }
    win_sorted = rows.sort_by { |r| [-r["hist_win_rate"].to_f, r["car_number"].to_i] }
    top3_sorted = rows.sort_by { |r| [-r["hist_top3_rate"].to_f, r["car_number"].to_i] }
    mark_sorted = rows.sort_by { |r| [-r["mark_score"].to_f, r["car_number"].to_i] }
    odds_sorted = rows.sort_by { |r| [r["odds_2shatan_min_first"].to_f, r["car_number"].to_i] }
    avg_rank_rank = avg_rank_sorted.each_with_index.to_h { |r, i| [r["car_number"], i + 1] }
    recent3_top3_rank = recent3_top3_sorted.each_with_index.to_h { |r, i| [r["car_number"], i + 1] }
    recent5_top3_rank = recent5_top3_sorted.each_with_index.to_h { |r, i| [r["car_number"], i + 1] }
    same_meet_prev_day_rank = same_meet_prev_day_sorted.each_with_index.to_h { |r, i| [r["car_number"], i + 1] }
    same_meet_avg_rank = same_meet_avg_sorted.each_with_index.to_h { |r, i| [r["car_number"], i + 1] }
    same_meet_recent3_synergy_rank = same_meet_recent3_synergy_sorted.each_with_index.to_h { |r, i| [r["car_number"], i + 1] }
    pair_i_top3_rank = pair_i_top3_sorted.each_with_index.to_h { |r, i| [r["car_number"], i + 1] }
    triplet_i_top3_rank = triplet_i_top3_sorted.each_with_index.to_h { |r, i| [r["car_number"], i + 1] }
    win_rank = win_sorted.each_with_index.to_h { |r, i| [r["car_number"], i + 1] }
    top3_rank = top3_sorted.each_with_index.to_h { |r, i| [r["car_number"], i + 1] }
    mark_rank = mark_sorted.each_with_index.to_h { |r, i| [r["car_number"], i + 1] }
    odds_rank = odds_sorted.each_with_index.to_h { |r, i| [r["car_number"], i + 1] }

    rows.each do |r|
      r["race_rel_hist_avg_rank_rank"] = avg_rank_rank[r["car_number"]].to_s
      r["race_rel_hist_recent3_top3_rate_rank"] = recent3_top3_rank[r["car_number"]].to_s
      r["race_rel_hist_recent5_top3_rate_rank"] = recent5_top3_rank[r["car_number"]].to_s
      r["race_rel_same_meet_prev_day_rank"] = same_meet_prev_day_rank[r["car_number"]].to_s
      r["race_rel_same_meet_avg_rank_rank"] = same_meet_avg_rank[r["car_number"]].to_s
      r["race_rel_same_meet_recent3_synergy_rank"] = same_meet_recent3_synergy_rank[r["car_number"]].to_s
      r["race_rel_pair_i_top3_rate_rank"] = pair_i_top3_rank[r["car_number"]].to_s
      r["race_rel_triplet_i_top3_rate_rank"] = triplet_i_top3_rank[r["car_number"]].to_s
      r["race_rel_hist_win_rate_rank"] = win_rank[r["car_number"]].to_s
      r["race_rel_hist_top3_rate_rank"] = top3_rank[r["car_number"]].to_s
      r["race_rel_mark_score_rank"] = mark_rank[r["car_number"]].to_s
      r["race_rel_odds_2shatan_rank"] = odds_rank[r["car_number"]].to_s
    end
  end

  def ratio(num, den)
    return "0.0" if den.zero?
    format("%.6f", num.to_f / den)
  end

  def smoothed_rate(num, den, prior, strength)
    den_f = den.to_f
    prior_f = prior.to_f
    return prior_f if den_f <= 0.0

    (num.to_f + (prior_f * strength.to_f)) / (den_f + strength.to_f)
  end

  def recent_rate_smoothed_f(stats, threshold_rank, window, prior, strength)
    recent = stats[:recent_ranks].first(window)
    return prior.to_f if recent.empty?

    hits = recent.count { |rank| rank <= threshold_rank }
    smoothed_rate(hits, recent.size, prior, strength)
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

  def safe_avg_rank_sort_value(v)
    x = v.to_f
    x.zero? ? 999.9 : x
  end

  def safe_same_meet_rank(v)
    x = v.to_i
    x <= 0 ? 999 : x
  end

  def same_meet_key_from_race(race)
    "#{race[:venue]}-#{race[:start_date].strftime('%Y%m%d')}"
  end

  def global_win_rate_prior
    return DEFAULT_WIN_PRIOR if @global_entries.zero?

    @global_wins.to_f / @global_entries
  end

  def global_top3_rate_prior
    return DEFAULT_TOP3_PRIOR if @global_entries.zero?

    @global_top3.to_f / @global_entries
  end

  def race_id_from_row(row)
    "#{row['race_date']}-#{row['venue']}-#{format('%02d', row['race_number'].to_i)}"
  end

  def update_same_meet_history(row, rank)
    key = [same_meet_key_from_row(row), row["player_name"].to_s]
    st = @same_meet_history[key]
    st[:count] += 1
    st[:rank_sum] += rank
    st[:prev_day_rank] = rank
  end

  def update_global_history(rank)
    @global_entries += 1
    @global_wins += 1 if rank == 1
    @global_top3 += 1 if rank <= 3
  end

  def same_meet_key_from_row(row)
    md = row["racedetail_id"].to_s.match(/^\d{2}(\d{8})\d{2}\d{4}$/)
    return "" if md.nil?
    "#{row['venue']}-#{md[1]}"
  end

  def same_meet_stats(race, player_name)
    @same_meet_history[[same_meet_key_from_race(race), player_name.to_s]] || { count: 0, rank_sum: 0, prev_day_rank: 0 }
  end

  def same_meet_prev_day_rank(race, player_name)
    same_meet_stats(race, player_name)[:prev_day_rank].to_i
  end

  def same_meet_prev_day_exists(race, player_name)
    same_meet_prev_day_rank(race, player_name) > 0 ? 1 : 0
  end

  def same_meet_avg_rank(race, player_name)
    st = same_meet_stats(race, player_name)
    return 0.0 if st[:count].zero?
    st[:rank_sum].to_f / st[:count]
  end

  def pair_context(player_name, entries, stats, player_top3_prior, global_top3_prior)
    others = entries.map { |e| e[:player_name].to_s }.uniq.reject { |n| n == player_name.to_s }
    return { count_total: 0.0, i_top3_rate_avg: 0.0, both_top3_rate_avg: 0.0 } if others.empty?

    counts = []
    i_rates = []
    both_rates = []
    others.each do |other|
      st = pair_history_stats(player_name, other)
      counts << st[:count].to_f
      other_stats = stats[other]
      other_prior = smoothed_rate(other_stats[:top3_count], other_stats[:count], global_top3_prior, PLAYER_PRIOR_STRENGTH)
      i_rates << smoothed_rate(st[:top3_counts][player_name.to_s], st[:count], player_top3_prior, PAIR_PRIOR_STRENGTH)
      both_prior = player_top3_prior * other_prior
      both_rates << smoothed_rate(st[:both_top3_count], st[:count], both_prior, PAIR_PRIOR_STRENGTH)
    end
    {
      count_total: counts.sum,
      i_top3_rate_avg: i_rates.sum / i_rates.size,
      both_top3_rate_avg: both_rates.sum / both_rates.size
    }
  end

  def triplet_context(player_name, entries, stats, player_top3_prior, global_top3_prior)
    others = entries.map { |e| e[:player_name].to_s }.uniq.reject { |n| n == player_name.to_s }
    combos = others.combination(2).to_a
    return { count_total: 0.0, i_top3_rate_avg: 0.0, all_top3_rate_avg: 0.0 } if combos.empty?

    counts = []
    i_rates = []
    all_rates = []
    combos.each do |a, b|
      st = triplet_history_stats(player_name, a, b)
      counts << st[:count].to_f
      a_stats = stats[a]
      b_stats = stats[b]
      a_prior = smoothed_rate(a_stats[:top3_count], a_stats[:count], global_top3_prior, PLAYER_PRIOR_STRENGTH)
      b_prior = smoothed_rate(b_stats[:top3_count], b_stats[:count], global_top3_prior, PLAYER_PRIOR_STRENGTH)
      i_rates << smoothed_rate(st[:top3_counts][player_name.to_s], st[:count], player_top3_prior, TRIPLET_PRIOR_STRENGTH)
      all_prior = player_top3_prior * a_prior * b_prior
      all_rates << smoothed_rate(st[:all_top3_count], st[:count], all_prior, TRIPLET_PRIOR_STRENGTH)
    end
    {
      count_total: counts.sum,
      i_top3_rate_avg: i_rates.sum / i_rates.size,
      all_top3_rate_avg: all_rates.sum / all_rates.size
    }
  end

  def pair_history_stats(a, b)
    @pair_history[[a.to_s, b.to_s].sort]
  end

  def triplet_history_stats(a, b, c)
    @triplet_history[[a.to_s, b.to_s, c.to_s].sort]
  end

  def update_pair_triplet_history(race_rows)
    participants = race_rows.map { |r| r["player_name"].to_s }.uniq
    top3_map = race_rows.each_with_object({}) do |r, h|
      h[r["player_name"].to_s] = r["rank"].to_i <= 3
    end

    participants.combination(2) do |a, b|
      st = pair_history_stats(a, b)
      st[:count] += 1
      st[:top3_counts][a] += 1 if top3_map[a]
      st[:top3_counts][b] += 1 if top3_map[b]
      st[:both_top3_count] += 1 if top3_map[a] && top3_map[b]
    end

    participants.combination(3) do |a, b, c|
      st = triplet_history_stats(a, b, c)
      st[:count] += 1
      st[:top3_counts][a] += 1 if top3_map[a]
      st[:top3_counts][b] += 1 if top3_map[b]
      st[:top3_counts][c] += 1 if top3_map[c]
      st[:all_top3_count] += 1 if top3_map[a] && top3_map[b] && top3_map[c]
    end
  end

  def mark_score(mark_symbol)
    case mark_symbol.to_s
    when "◎" then 5.0
    when "○" then 4.0
    when "▲" then 3.0
    when "△" then 2.0
    when "×", "注" then 1.0
    else 0.0
    end
  end

  def check_lightgbm!
    GK::LightGBMUtils.ensure_lightgbm!
  end

  def predict_scores(rows, model_path, encoders_path, feature_columns)
    encoders = JSON.parse(File.read(encoders_path, encoding: "UTF-8"))
    categorical_features = GK::FeatureSchema.categorical_features_for(feature_columns)
    Dir.mktmpdir("gk-predict-") do |tmp|
      data_tsv = File.join(tmp, "data.tsv")
      pred_txt = File.join(tmp, "pred.txt")
      conf = File.join(tmp, "predict.conf")

      File.open(data_tsv, "w") do |f|
        rows.each do |r|
          xs = feature_columns.map do |name|
          if categorical_features.include?(name)
            (encoders.fetch(name, {})[r[name].to_s] || -1).to_s
          else
            GK::FeatureSchema.to_float_string(r[name])
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

  def predict_exacta_scores(rows)
    return nil unless exacta_model_available?

    pair_rows = build_exacta_pair_rows(rows)
    return nil if pair_rows.empty?

    scores = predict_scores_exacta_pair(pair_rows)
    pair_rows.each_with_index.each_with_object({}) do |(pair_row, idx), h|
      key = [pair_row["first_car_number"].to_i, pair_row["second_car_number"].to_i]
      h[key] = scores[idx]
    end
  end

  def predict_scores_exacta_pair(rows)
    encoders = JSON.parse(File.read(@encoders_exacta, encoding: "UTF-8"))
    feature_columns = @feature_columns_exacta
    categorical_features = GK::ExactaFeatureSchema.categorical_features_for(feature_columns)

    Dir.mktmpdir("gk-predict-exacta-") do |tmp|
      data_tsv = File.join(tmp, "data.tsv")
      pred_txt = File.join(tmp, "pred.txt")
      conf = File.join(tmp, "predict.conf")

      File.open(data_tsv, "w") do |f|
        rows.each do |r|
          xs = feature_columns.map do |name|
            if categorical_features.include?(name)
              (encoders.fetch(name, {})[r[name].to_s] || -1).to_s
            else
              GK::ExactaFeatureSchema.to_float_string(r[name])
            end
          end
          f.puts((["0"] + xs).join("\t"))
        end
      end

      File.write(conf, <<~CONF)
        task=predict
        data=#{data_tsv}
        input_model=#{@model_exacta}
        output_result=#{pred_txt}
        header=false
      CONF
      _out, err, status = Open3.capture3("lightgbm", "config=#{conf}")
      raise "lightgbm exacta predict failed: #{err}" unless status.success?
      File.readlines(pred_txt, chomp: true).map(&:to_f)
    end
  end

  def build_exacta_pair_rows(rows)
    rows.flat_map do |first|
      rows.map do |second|
        next if first["car_number"] == second["car_number"]

        build_exacta_pair_row(first, second)
      end
    end.compact
  end

  def build_exacta_pair_row(first, second)
    row = {
      "first_car_number" => first["car_number"].to_s,
      "second_car_number" => second["car_number"].to_s
    }

    GK::ExactaFeatureSchema::SOURCE_FEATURE_COLUMNS.each do |col|
      row["first_#{col}"] = first[col]
      row["second_#{col}"] = second[col]
    end

    GK::ExactaFeatureSchema::SOURCE_NUMERIC_FEATURES.each do |col|
      row["diff_#{col}"] = first[col].to_f - second[col].to_f
    end
    row
  end

  def load_feature_columns(model_path, default_columns)
    return default_columns unless model_path && !model_path.to_s.empty?

    path = File.join(File.dirname(model_path), "feature_columns.json")
    return default_columns unless File.exist?(path)

    JSON.parse(File.read(path, encoding: "UTF-8"))
  end

  def exacta_model_available?
    @use_exacta_model && File.exist?(@model_exacta.to_s) && File.exist?(@encoders_exacta.to_s)
  end

  def validate_model_manifest!(model_path, feature_columns)
    return if model_path.to_s.empty?

    manifest_path = File.join(File.dirname(model_path), "model_manifest.json")
    manifest = GK::ModelManifest.load(manifest_path)
    GK::ModelManifest.validate_feature_columns!(manifest, feature_columns)
  end

  def print_rankings(race, rows)
    puts "# レース: #{race[:venue]} #{race[:race_date]} #{race[:race_number]}R (#{race[:racedetail_id]})"
    print_entry_list(rows)
    puts "## 1着予測ランキング"
    rank_rows = rows.sort_by { |r| -r["score_top1"] }.each_with_index.map do |r, idx|
      [
        (idx + 1).to_s,
        r["car_number"].to_s,
        r["player_name"].to_s,
        r["mark_symbol"].to_s,
        r["leg_style"].to_s,
        format("%.6f", r["score_top1"].to_f),
        format("%.6f", r["score_top3"].to_f)
      ]
    end
    print_table(%w[順位 車番 選手 印 脚質 1着確率 3着内確率], rank_rows, right_align: [0, 1, 5, 6])
    print_confidence(rows)
  end

  def print_exotics(_race, rows, pair_odds, trifecta_odds, exacta_scores)
    cars = rows.map do |r|
      {
        car_number: r["car_number"].to_i,
        player_name: r["player_name"],
        top3_score: clamp01(r["score_top3"]),
        top1_score: r["score_top1"].to_f
      }
    end
    p_win = softmax_win(cars)
    p_top3 = cars.to_h { |c| [c[:car_number], c[:top3_score]] }
    exacta = []
    trifecta = []
    cars.each do |i|
      cars.each do |j|
        next if i[:car_number] == j[:car_number]
        score = if exacta_scores
          exacta_scores[[i[:car_number], j[:car_number]]] || 0.0
        else
          GK::ExoticScoring.score_exacta(
            p_win: p_win,
            p_top3: p_top3,
            first_car: i[:car_number],
            second_car: j[:car_number],
            params: @exotic_params
          )
        end
        odd = pair_odds[[i[:car_number], j[:car_number]]]
        ev = odd.nil? ? nil : score * odd
        exacta << [i, j, score, odd, ev]
        cars.each do |k|
          next if [i[:car_number], j[:car_number]].include?(k[:car_number])
          score3 = GK::ExoticScoring.score_trifecta(
            p_win: p_win,
            p_top3: p_top3,
            first_car: i[:car_number],
            second_car: j[:car_number],
            third_car: k[:car_number],
            params: @exotic_params
          )
          odd3 = trifecta_odds[[i[:car_number], j[:car_number], k[:car_number]]]
          ev3 = odd3.nil? ? nil : score3 * odd3
          trifecta << [i, j, k, score3, odd3, ev3]
        end
      end
    end
    print_no_bet_advice(rows)
    exacta_rows = exacta
      .sort_by { |x| exotic_sort_key(x[2], x[3], x[4]) }
      .select { |x| x[4].nil? || x[4] >= @exacta_min_ev }
      .first(@exacta_top)
      .each_with_index.map do |(i, j, score, odd, ev), idx|
      stake = suggest_stake(score, odd)
      [
        (idx + 1).to_s,
        "#{i[:car_number]}-#{j[:car_number]}",
        format("%.10f", score),
        odd ? format("%.2f", odd) : "-",
        ev ? format("%.3f", ev) : "-",
        stake.to_s,
        "#{i[:player_name]}-#{j[:player_name]}"
      ]
    end
    trifecta_rows = trifecta.sort_by { |x| exotic_sort_key(x[3], x[4], x[5]) }.first(@trifecta_top).each_with_index.map do |(i, j, k, s, odd, ev), idx|
      stake = suggest_stake(s, odd)
      [
        (idx + 1).to_s,
        "#{i[:car_number]}-#{j[:car_number]}-#{k[:car_number]}",
        format("%.10f", s),
        odd ? format("%.2f", odd) : "-",
        ev ? format("%.3f", ev) : "-",
        stake.to_s,
        "#{i[:player_name]}-#{j[:player_name]}-#{k[:player_name]}"
      ]
    end
    exacta_lines = table_lines(%w[順位 買い目 スコア オッズ EV 推奨額 選手], exacta_rows, right_align: [0, 2, 3, 4, 5])
    trifecta_lines = table_lines(%w[順位 買い目 スコア オッズ EV 推奨額 選手], trifecta_rows, right_align: [0, 2, 3, 4, 5])
    exacta_lines += betting_summary_lines(exacta_rows)
    exacta_lines += hedge_summary_lines(exacta_rows)
    trifecta_lines += betting_summary_lines(trifecta_rows)
    trifecta_lines += hedge_summary_lines(trifecta_rows)
    exacta_source = exacta_scores ? "exacta_model" : "heuristic"
    print_side_by_side_blocks("## 2連単 Top #{@exacta_top} [#{@bet_style}/#{exacta_source}]", exacta_lines, "## 3連単 Top #{@trifecta_top} [#{@bet_style}]", trifecta_lines)
  end

  def exotic_sort_key(score, odd, ev)
    odd_rank = odd || Float::INFINITY
    ev_rank = ev ? -ev : 1.0
    score_rank = -score
    case @bet_style
    when "solid"
      [odd_rank, ev_rank, score_rank]
    when "value"
      [ev_rank, score_rank, odd_rank]
    else
      [score_rank, ev_rank, odd_rank]
    end
  end

  def clamp01(v)
    x = v.to_f
    return 0.0 if x.nan? || x.negative?
    return 1.0 if x > 1.0
    x
  end

  def softmax_win(cars)
    GK::ExoticScoring.win_probs(cars, @win_temperature, car_key: :car_number, win_key: :top1_score)
  end

  def build_exotic_params(exotic_profile:, win_temperature:, exacta_win_exp:, exacta_second_exp:, exacta_second_win_exp:, trifecta_win_exp:, trifecta_second_exp:, trifecta_third_exp:)
    base = GK::ExoticScoring.default_params
    base["win_temperature"] = 0.15 if exotic_profile.to_s.empty? && win_temperature.nil?
    unless exotic_profile.to_s.empty?
      base = GK::ExoticScoring.merge_params(base, GK::ExoticScoring.load_profile(exotic_profile))
    end

    overrides = {}
    overrides["win_temperature"] = win_temperature unless win_temperature.nil?
    unless exacta_win_exp.nil?
      overrides["exacta"] ||= {}
      overrides["exacta"]["win_exp"] = exacta_win_exp
    end
    unless exacta_second_exp.nil?
      overrides["exacta"] ||= {}
      overrides["exacta"]["second_exp"] = exacta_second_exp
    end
    unless exacta_second_win_exp.nil?
      overrides["exacta"] ||= {}
      overrides["exacta"]["second_win_exp"] = exacta_second_win_exp
    end
    unless trifecta_win_exp.nil?
      overrides["trifecta"] ||= {}
      overrides["trifecta"]["win_exp"] = trifecta_win_exp
    end
    unless trifecta_second_exp.nil?
      overrides["trifecta"] ||= {}
      overrides["trifecta"]["second_exp"] = trifecta_second_exp
    end
    unless trifecta_third_exp.nil?
      overrides["trifecta"] ||= {}
      overrides["trifecta"]["third_exp"] = trifecta_third_exp
    end
    GK::ExoticScoring.merge_params(base, overrides)
  end

  def print_confidence(rows)
    sorted = rows.sort_by { |r| -r["score_top1"].to_f }
    top1 = sorted[0]["score_top1"].to_f
    top2 = sorted[1] ? sorted[1]["score_top1"].to_f : 0.0
    gap = top1 - top2
    puts format("予測信頼度: 1位と2位の差=%.6f (閾値=%.6f)", gap, @no_bet_gap_threshold)
  end

  def print_no_bet_advice(rows)
    sorted = rows.sort_by { |r| -r["score_top1"].to_f }
    top1 = sorted[0]["score_top1"].to_f
    top2 = sorted[1] ? sorted[1]["score_top1"].to_f : 0.0
    gap = top1 - top2
    if gap < @no_bet_gap_threshold
      puts format("判定: 見送り (1位と2位の差=%.6f < %.6f)", gap, @no_bet_gap_threshold)
    else
      puts format("判定: 購入候補 (1位と2位の差=%.6f >= %.6f)", gap, @no_bet_gap_threshold)
    end
  end

  def suggest_stake(prob, odd)
    return 0 if odd.nil?
    b = odd - 1.0
    return 0 if b <= 0.0
    p = clamp01(prob)
    q = 1.0 - p
    kelly = ((b * p) - q) / b
    frac = [kelly, 0.0].max
    frac = [frac, @kelly_cap].min
    raw = (@bankroll * frac).floor
    (raw / @unit) * @unit
  end

  def betting_summary_lines(rows)
    count = rows.size
    flat_total = count * @unit
    recommended_total = rows.sum { |r| r[5].to_i }
    bankroll_ratio = @bankroll.zero? ? 0.0 : recommended_total.to_f / @bankroll
    odds = rows.filter_map do |r|
      value = r[3].to_s
      next nil if value == "-"
      value.to_f
    end
    min_return = odds.empty? ? nil : (odds.min * @unit).round
    max_return = odds.empty? ? nil : (odds.max * @unit).round
    [
      "均等買い総額: #{flat_total}円 (#{@unit}円 x #{count}点)",
      "均等買い払戻レンジ: #{min_return || '-'}円 〜 #{max_return || '-'}円",
      "推奨額合計: #{recommended_total}円 (bankroll比 #{format('%.1f', bankroll_ratio * 100)}%)"
    ]
  end

  def hedge_summary_lines(rows)
    plan = build_hedge_plan(rows)
    return ["トリガミ回避買い: 不可"] if plan.nil?

    lines = [
      "トリガミ回避買い: 総額 #{plan[:total_stake]}円 / 最低払戻 #{plan[:min_return]}円 / 最低利益 #{plan[:min_profit]}円",
    ]
    plan[:stakes].each_slice(3) do |chunk|
      lines << "配分: #{chunk.map { |bet, stake| "#{bet}=#{stake}円" }.join(', ')}"
    end
    lines
  end

  def build_hedge_plan(rows)
    bets = rows.filter_map do |r|
      odd_text = r[3].to_s
      next nil if odd_text == "-"
      odd = odd_text.to_f
      next nil if odd <= 1.0
      { bet: r[1].to_s, odd: odd }
    end
    return nil if bets.empty?

    inv_sum = bets.sum { |b| 1.0 / b[:odd] }
    return nil if inv_sum >= 1.0

    target_return = ((@unit / (1.0 - inv_sum)).ceil / @unit) * @unit
    max_iterations = 10_000

    max_iterations.times do
      stakes = bets.map do |b|
        units = (target_return / (b[:odd] * @unit)).ceil
        [b[:bet], units * @unit, b[:odd]]
      end
      total_stake = stakes.sum { |_, stake, _| stake }
      returns = stakes.map { |_, stake, odd| (stake * odd).round }
      min_return = returns.min
      min_profit = min_return - total_stake
      if min_profit >= 0
        return {
          total_stake: total_stake,
          min_return: min_return,
          min_profit: min_profit,
          stakes: stakes.to_h { |bet, stake, _| [bet, stake] }
        }
      end
      target_return += @unit
    end

    nil
  end

  def print_entry_list(rows)
    puts "## 出走リスト"
    entry_rows = rows.sort_by { |r| r["car_number"].to_i }.map do |r|
      [
        r["car_number"].to_s,
        r["player_name"].to_s,
        r["mark_symbol"].to_s,
        r["leg_style"].to_s,
        format("%.3f", r["odds_2shatan_min_first"].to_f)
      ]
    end
    print_table(["車番", "選手", "印", "脚質", "2連単最小オッズ"], entry_rows, right_align: [0, 4])
  end

  def print_odds_source_note
    mode = @use_cache ? "cache" : "live(no-cache)"
    puts "オッズ取得モード: #{mode}"
    puts "買い目スタイル: #{@bet_style}"
    puts "2連単スコア源: #{exacta_model_available? ? 'exacta専用モデル' : 'top1/top3合成(従来)'}"
    puts "注記: この予測は2連単オッズ特徴量を使うため、オッズ更新で予測も変動します。"
  end

  def verify_odds_direction(html, pair_odds, trifecta_odds)
    p2 = GK::HtmlUtils.parse_2shatan_popular_odds(html).first(10)
    p3 = GK::HtmlUtils.parse_3rentan_popular_odds(html).first(10)
    miss2 = p2.filter_map do |a, b, odd|
      parsed = pair_odds[[a, b]]
      next nil if parsed && (parsed - odd).abs < 1e-6
      "#{a}-#{b}: popular=#{odd} parsed=#{parsed || '-'}"
    end
    miss3 = p3.filter_map do |a, b, c, odd|
      parsed = trifecta_odds[[a, b, c]]
      next nil if parsed && (parsed - odd).abs < 1e-6
      "#{a}-#{b}-#{c}: popular=#{odd} parsed=#{parsed || '-'}"
    end
    return if miss2.empty? && miss3.empty?

    warn "WARN: オッズ抽出と人気順に不一致があります。"
    miss2.first(5).each { |line| warn "WARN: 2連単 #{line}" }
    miss3.first(5).each { |line| warn "WARN: 3連単 #{line}" }
  end

  def print_table(headers, rows, right_align: [])
    puts table_lines(headers, rows, right_align: right_align)
  end

  def format_row(cells, widths, right_align)
    cells.each_with_index.map do |cell, i|
      text = cell.to_s
      pad_display(text, widths[i], right: right_align.include?(i))
    end.join(" | ")
  end

  def display_width(text)
    text.each_char.sum { |ch| ch.bytesize == 1 ? 1 : 2 }
  end

  def pad_display(text, width, right: false)
    pad = [width - display_width(text), 0].max
    right ? (" " * pad) + text : text + (" " * pad)
  end

  def table_lines(headers, rows, right_align: [])
    matrix = [headers] + rows
    widths = headers.each_index.map do |i|
      matrix.map { |r| display_width(r[i].to_s) }.max
    end
    sep = "+-#{widths.map { |w| "-" * w }.join("-+-")}-+"
    lines = []
    lines << sep
    lines << "| #{format_row(headers, widths, right_align)} |"
    lines << sep
    rows.each { |r| lines << "| #{format_row(r, widths, right_align)} |" }
    lines << sep
    lines
  end

  def print_side_by_side_blocks(left_title, left_lines, right_title, right_lines, spacer: "    ")
    puts "#{left_title}#{spacer}#{right_title}"
    left_width = ([left_title] + left_lines).map { |s| display_width(s) }.max
    max_rows = [left_lines.size, right_lines.size].max
    max_rows.times do |i|
      l = left_lines[i] || ""
      r = right_lines[i] || ""
      puts "#{pad_display(l, left_width)}#{spacer}#{r}"
    end
  end
end

options = {
  url: nil,
  model_top3: File.join("data", "ml", "model.txt"),
  encoders_top3: File.join("data", "ml", "encoders.json"),
  model_top1: File.join("data", "ml_top1", "model.txt"),
  encoders_top1: File.join("data", "ml_top1", "encoders.json"),
  model_exacta: File.join("data", "ml_exacta", "model.txt"),
  encoders_exacta: File.join("data", "ml_exacta", "encoders.json"),
  use_exacta_model: false,
  raw_dir: File.join("data", "raw"),
  cache_dir: File.join("data", "raw_html", "predict"),
  win_temperature: nil,
  exacta_top: 20,
  trifecta_top: 20,
  use_cache: false,
  no_bet_gap_threshold: 0.03,
  exacta_min_ev: 1.0,
  bankroll: 10_000,
  unit: 100,
  kelly_cap: 0.03,
  bet_style: "standard",
  exotic_profile: nil,
  exacta_win_exp: nil,
  exacta_second_exp: nil,
  exacta_second_win_exp: nil,
  trifecta_win_exp: nil,
  trifecta_second_exp: nil,
  trifecta_third_exp: nil
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: ruby scripts/predict_race.rb --url https://keirin.kdreams.jp/.../racedetail/xxxxxxxxxxxxxxxx/"
  opts.on("--url URL", "race detail url") { |v| options[:url] = v }
  opts.on("--model-top3 PATH", "top3 model path") { |v| options[:model_top3] = v }
  opts.on("--encoders-top3 PATH", "top3 encoders path") { |v| options[:encoders_top3] = v }
  opts.on("--model-top1 PATH", "top1 model path") { |v| options[:model_top1] = v }
  opts.on("--encoders-top1 PATH", "top1 encoders path") { |v| options[:encoders_top1] = v }
  opts.on("--model-exacta PATH", "exacta model path") { |v| options[:model_exacta] = v }
  opts.on("--encoders-exacta PATH", "exacta encoders path") { |v| options[:encoders_exacta] = v }
  opts.on("--[no-]exacta-model", "use exacta model for exacta score (default: false)") { |v| options[:use_exacta_model] = v }
  opts.on("--raw-dir DIR", "history csv dir") { |v| options[:raw_dir] = v }
  opts.on("--cache-dir DIR", "html cache dir") { |v| options[:cache_dir] = v }
  opts.on("--win-temperature X", Float, "temperature for win softmax (default: profile or 0.15)") { |v| options[:win_temperature] = v }
  opts.on("--exotic-profile PATH", "exotic score profile json path") { |v| options[:exotic_profile] = v }
  opts.on("--exacta-win-exp X", Float, "exacta: exponent for first-car win prob") { |v| options[:exacta_win_exp] = v }
  opts.on("--exacta-second-exp X", Float, "exacta: exponent for second-car top3 prob") { |v| options[:exacta_second_exp] = v }
  opts.on("--exacta-second-win-exp X", Float, "exacta: exponent for second-car win prob") { |v| options[:exacta_second_win_exp] = v }
  opts.on("--trifecta-win-exp X", Float, "trifecta: exponent for first-car win prob") { |v| options[:trifecta_win_exp] = v }
  opts.on("--trifecta-second-exp X", Float, "trifecta: exponent for second-car top3 prob") { |v| options[:trifecta_second_exp] = v }
  opts.on("--trifecta-third-exp X", Float, "trifecta: exponent for third-car top3 prob") { |v| options[:trifecta_third_exp] = v }
  opts.on("--exacta-top N", Integer, "exacta top N") { |v| options[:exacta_top] = v }
  opts.on("--trifecta-top N", Integer, "trifecta top N") { |v| options[:trifecta_top] = v }
  opts.on("--bet-gap-threshold X", Float, "no-bet threshold by top1 gap (default: 0.03)") { |v| options[:no_bet_gap_threshold] = v }
  opts.on("--exacta-min-ev X", Float, "minimum EV threshold for exacta output (default: 1.0)") { |v| options[:exacta_min_ev] = v }
  opts.on("--bankroll N", Integer, "bankroll for stake suggestion (default: 10000)") { |v| options[:bankroll] = v }
  opts.on("--unit N", Integer, "bet unit for stake suggestion (default: 100)") { |v| options[:unit] = v }
  opts.on("--kelly-cap X", Float, "cap for Kelly fraction (default: 0.03)") { |v| options[:kelly_cap] = v }
  opts.on("--bet-style STYLE", "bet style: standard / solid / value (default: standard)") { |v| options[:bet_style] = v }
  opts.on("--[no-]cache", "use cache html (default: false)") { |v| options[:use_cache] = v }
end

# OptionParser treats long options starting with "--no-" specially and can
# misparse unrelated flags when "--[no-]cache" is also defined.
ARGV.map! { |arg| arg == "--no-bet-gap-threshold" ? "--bet-gap-threshold" : arg }
parser.parse!

if options[:url].to_s.empty?
  warn parser.to_s
  exit 1
end

unless %w[standard solid value].include?(options[:bet_style])
  warn "--bet-style must be one of: standard, solid, value"
  exit 1
end

if options[:unit] <= 0
  warn "--unit must be > 0"
  exit 1
end

if options[:bankroll] < 0
  warn "--bankroll must be >= 0"
  exit 1
end

if options[:kelly_cap] < 0.0 || options[:kelly_cap] > 1.0
  warn "--kelly-cap must be between 0 and 1"
  exit 1
end

if options[:no_bet_gap_threshold] < 0.0
  warn "--bet-gap-threshold must be >= 0"
  exit 1
end

if options[:exacta_min_ev] < 0.0
  warn "--exacta-min-ev must be >= 0"
  exit 1
end

RacePredictor.new(
  url: options[:url],
  model_top3: options[:model_top3],
  encoders_top3: options[:encoders_top3],
  model_top1: options[:model_top1],
  encoders_top1: options[:encoders_top1],
  model_exacta: options[:model_exacta],
  encoders_exacta: options[:encoders_exacta],
  use_exacta_model: options[:use_exacta_model],
  raw_dir: options[:raw_dir],
  cache_dir: options[:cache_dir],
  win_temperature: options[:win_temperature],
  exacta_top: options[:exacta_top],
  trifecta_top: options[:trifecta_top],
  use_cache: options[:use_cache],
  no_bet_gap_threshold: options[:no_bet_gap_threshold],
  exacta_min_ev: options[:exacta_min_ev],
  bankroll: options[:bankroll],
  unit: options[:unit],
  kelly_cap: options[:kelly_cap],
  bet_style: options[:bet_style],
  exotic_profile: options[:exotic_profile],
  exacta_win_exp: options[:exacta_win_exp],
  exacta_second_exp: options[:exacta_second_exp],
  exacta_second_win_exp: options[:exacta_second_win_exp],
  trifecta_win_exp: options[:trifecta_win_exp],
  trifecta_second_exp: options[:trifecta_second_exp],
  trifecta_third_exp: options[:trifecta_third_exp]
).run
