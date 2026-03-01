#!/usr/bin/env ruby
# frozen_string_literal: true

require "csv"
require "date"
require "digest"
require "fileutils"
require "optparse"
require_relative "lib/html_utils"
require_relative "lib/feature_engine_common"
require_relative "../core/features/feature_builder"

class FeatureBuilder
  DEFAULT_WIN_PRIOR = (1.0 / 7.0)
  DEFAULT_TOP3_PRIOR = (3.0 / 7.0)
  PLAYER_PRIOR_STRENGTH = 18.0
  RECENT_PRIOR_STRENGTH = 5.0
  PAIR_PRIOR_STRENGTH = 8.0
  TRIPLET_PRIOR_STRENGTH = 8.0

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
    hist_recent3_weighted_avg_rank
    hist_recent3_win_rate
    hist_recent3_top3_rate
    recent3_vs_hist_top3_delta
    hist_recent5_weighted_avg_rank
    hist_recent5_win_rate
    hist_recent5_top3_rate
    hist_days_since_last
    same_meet_day_number
    same_meet_prev_day_exists
    same_meet_prev_day_rank
    same_meet_prev_day_top1
    same_meet_prev_day_top3
    same_meet_races
    same_meet_avg_rank
    same_meet_prev_day_rank_inv
    same_meet_recent3_synergy
    pair_hist_count_total
    pair_hist_i_top3_rate_avg
    pair_hist_both_top3_rate_avg
    triplet_hist_count_total
    triplet_hist_i_top3_rate_avg
    triplet_hist_all_top3_rate_avg
    race_rel_hist_avg_rank_rank
    race_rel_hist_recent3_top3_rate_rank
    race_rel_hist_recent5_top3_rate_rank
    race_rel_same_meet_prev_day_rank
    race_rel_same_meet_avg_rank_rank
    race_rel_same_meet_recent3_synergy_rank
    race_rel_pair_i_top3_rate_rank
    race_rel_triplet_i_top3_rate_rank
    race_rel_hist_win_rate_rank
    race_rel_hist_top3_rate_rank
    mark_symbol
    leg_style
    mark_score
    race_rel_mark_score_rank
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
    @same_meet_stats = {}
    @pair_stats = {}
    @triplet_stats = {}
    @global_entries = 0
    @global_wins = 0
    @global_top3 = 0
    @race_cache_context = {}
    @race_feature_builder = GK::Core::Features::FeatureBuilder.from_block do |race_rows:, date:, race_context:, global_win_prior:, global_top3_prior:, field_size:|
      prepared = prepare_race_rows(
        race_rows: race_rows,
        global_win_prior: global_win_prior,
        global_top3_prior: global_top3_prior,
        race_context: race_context
      )
      build_race_features(prepared: prepared, date: date, field_size: field_size)
    end
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
      global_win_prior = global_win_rate_prior
      global_top3_prior = global_top3_rate_prior
      race_features = @race_feature_builder.build(
        race_rows: race_rows,
        date: date,
        race_context: race_context,
        global_win_prior: global_win_prior,
        global_top3_prior: global_top3_prior,
        field_size: field_size
      )
      GK::FeatureEngineCommon.enrich_relative_ranks!(race_features)
      features.concat(race_features)

      race_rows.each do |r|
        rank_i = r["rank"].to_i
        update_stats(r["player_name"], rank_i, date)
        update_same_meet_stats(r, rank_i)
        update_global_stats(rank_i)
      end
      update_pair_triplet_stats(race_rows)
    end

    deduped = features.uniq { |r| [r["race_id"], r["car_number"]] }
    deduped.sort_by { |r| [r["race_date"], r["venue"], r["race_number"].to_i, r["rank"].to_i] }
  end

  def race_id_from_row(row)
    "#{row['race_date']}-#{row['venue']}-#{format('%02d', row['race_number'].to_i)}"
  end

  def prepare_race_rows(race_rows:, global_win_prior:, global_top3_prior:, race_context:)
    prepared = race_rows.map do |r|
      stats = stats_for(r["player_name"])
      car_no = r["car_number"].to_i
      cache = race_context[car_no] || {}
      hist_win_rate_f = smoothed_rate(stats[:win_count], stats[:count], global_win_prior, PLAYER_PRIOR_STRENGTH)
      hist_top3_rate_f = smoothed_rate(stats[:top3_count], stats[:count], global_top3_prior, PLAYER_PRIOR_STRENGTH)
      hist_recent3_win_rate_f = recent_rate_smoothed_f(stats, 1, 3, hist_win_rate_f, RECENT_PRIOR_STRENGTH)
      hist_recent3_top3_rate_f = recent_rate_smoothed_f(stats, 3, 3, hist_top3_rate_f, RECENT_PRIOR_STRENGTH)
      hist_recent5_win_rate_f = recent_rate_smoothed_f(stats, 1, 5, hist_win_rate_f, RECENT_PRIOR_STRENGTH)
      hist_recent5_top3_rate_f = recent_rate_smoothed_f(stats, 3, 5, hist_top3_rate_f, RECENT_PRIOR_STRENGTH)
      pair_ctx = pair_context(r["player_name"], race_rows, hist_top3_rate_f, global_top3_prior)
      triplet_ctx = triplet_context(r["player_name"], race_rows, hist_top3_rate_f, global_top3_prior)
      {
        row: r,
        stats: stats,
        same_meet_stats: same_meet_stats_for(r),
        pair_ctx: pair_ctx,
        triplet_ctx: triplet_ctx,
        hist_win_rate_f: hist_win_rate_f,
        hist_top3_rate_f: hist_top3_rate_f,
        hist_avg_rank_f: avg_rank_f(stats),
        hist_recent3_win_rate_f: hist_recent3_win_rate_f,
        hist_recent3_top3_rate_f: hist_recent3_top3_rate_f,
        hist_recent5_win_rate_f: hist_recent5_win_rate_f,
        hist_recent5_top3_rate_f: hist_recent5_top3_rate_f,
        mark_symbol: cache[:mark_symbol] || mark_from_raw_cells(r["raw_cells"]),
        leg_style: cache[:leg_style].to_s,
        odds_2shatan_min_first_f: cache[:odds_2shatan_min_first] || 9999.9
      }
    end

    prepared.each do |p|
      p[:mark_score_f] = mark_score(p[:mark_symbol])
      p[:same_meet_prev_day_rank_f] = same_meet_prev_day_rank_f(p[:same_meet_stats])
      p[:same_meet_avg_rank_f] = same_meet_avg_rank_f(p[:same_meet_stats])
      p[:recent3_vs_hist_top3_delta_f] = p[:hist_recent3_top3_rate_f] - p[:hist_top3_rate_f]
      p[:same_meet_prev_day_rank_inv_f] = same_meet_prev_day_rank_inv_f(p[:same_meet_stats])
      p[:same_meet_recent3_synergy_f] = p[:same_meet_prev_day_rank_inv_f] * p[:hist_recent3_top3_rate_f]
      p[:pair_hist_count_total_f] = p[:pair_ctx][:count_total]
      p[:pair_hist_i_top3_rate_avg_f] = p[:pair_ctx][:i_top3_rate_avg]
      p[:pair_hist_both_top3_rate_avg_f] = p[:pair_ctx][:both_top3_rate_avg]
      p[:triplet_hist_count_total_f] = p[:triplet_ctx][:count_total]
      p[:triplet_hist_i_top3_rate_avg_f] = p[:triplet_ctx][:i_top3_rate_avg]
      p[:triplet_hist_all_top3_rate_avg_f] = p[:triplet_ctx][:all_top3_rate_avg]
    end

    prepared
  end

  def build_race_features(prepared:, date:, field_size:)
    prepared.map do |p|
      r = p[:row]
      stats = p[:stats]
      same_meet = p[:same_meet_stats]
      rank = r["rank"].to_i

      {
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
        "hist_win_rate" => format("%.6f", p[:hist_win_rate_f]),
        "hist_top3_rate" => format("%.6f", p[:hist_top3_rate_f]),
        "hist_avg_rank" => avg_rank(stats),
        "hist_last_rank" => stats[:last_rank].to_s,
        "hist_recent3_weighted_avg_rank" => recent_weighted_avg_rank(stats, 3),
        "hist_recent3_win_rate" => format("%.6f", p[:hist_recent3_win_rate_f]),
        "hist_recent3_top3_rate" => format("%.6f", p[:hist_recent3_top3_rate_f]),
        "recent3_vs_hist_top3_delta" => format("%.6f", p[:recent3_vs_hist_top3_delta_f]),
        "hist_recent5_weighted_avg_rank" => recent_weighted_avg_rank(stats, 5),
        "hist_recent5_win_rate" => format("%.6f", p[:hist_recent5_win_rate_f]),
        "hist_recent5_top3_rate" => format("%.6f", p[:hist_recent5_top3_rate_f]),
        "hist_days_since_last" => days_since_last(stats, date).to_s,
        "same_meet_day_number" => same_meet_day_number(r).to_s,
        "same_meet_prev_day_exists" => same_meet[:prev_day_rank] > 0 ? "1" : "0",
        "same_meet_prev_day_rank" => same_meet[:prev_day_rank].to_s,
        "same_meet_prev_day_top1" => same_meet[:prev_day_rank] == 1 ? "1" : "0",
        "same_meet_prev_day_top3" => (same_meet[:prev_day_rank] >= 1 && same_meet[:prev_day_rank] <= 3) ? "1" : "0",
        "same_meet_races" => same_meet[:count].to_s,
        "same_meet_avg_rank" => same_meet_avg_rank(same_meet),
        "same_meet_prev_day_rank_inv" => format("%.6f", p[:same_meet_prev_day_rank_inv_f]),
        "same_meet_recent3_synergy" => format("%.6f", p[:same_meet_recent3_synergy_f]),
        "pair_hist_count_total" => format("%.6f", p[:pair_hist_count_total_f]),
        "pair_hist_i_top3_rate_avg" => format("%.6f", p[:pair_hist_i_top3_rate_avg_f]),
        "pair_hist_both_top3_rate_avg" => format("%.6f", p[:pair_hist_both_top3_rate_avg_f]),
        "triplet_hist_count_total" => format("%.6f", p[:triplet_hist_count_total_f]),
        "triplet_hist_i_top3_rate_avg" => format("%.6f", p[:triplet_hist_i_top3_rate_avg_f]),
        "triplet_hist_all_top3_rate_avg" => format("%.6f", p[:triplet_hist_all_top3_rate_avg_f]),
        "race_rel_hist_avg_rank_rank" => "0",
        "race_rel_hist_recent3_top3_rate_rank" => "0",
        "race_rel_hist_recent5_top3_rate_rank" => "0",
        "race_rel_same_meet_prev_day_rank" => "0",
        "race_rel_same_meet_avg_rank_rank" => "0",
        "race_rel_same_meet_recent3_synergy_rank" => "0",
        "race_rel_pair_i_top3_rate_rank" => "0",
        "race_rel_triplet_i_top3_rate_rank" => "0",
        "race_rel_hist_win_rate_rank" => "0",
        "race_rel_hist_top3_rate_rank" => "0",
        "mark_symbol" => p[:mark_symbol],
        "leg_style" => p[:leg_style],
        "mark_score" => format("%.1f", p[:mark_score_f]),
        "race_rel_mark_score_rank" => "0",
        "odds_2shatan_min_first" => format("%.6f", p[:odds_2shatan_min_first_f]),
        "race_rel_odds_2shatan_rank" => "0",
        "race_field_size" => field_size.to_s
      }
    end
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

  def same_meet_key(row)
    racedetail_id = row["racedetail_id"].to_s
    md = racedetail_id.match(/^\d{2}(\d{8})\d{2}\d{4}$/)
    return "" if md.nil?

    "#{row['venue']}-#{md[1]}"
  end

  def same_meet_day_number(row)
    racedetail_id = row["racedetail_id"].to_s
    racedetail_id[/^\d{2}\d{8}(\d{2})\d{4}$/, 1].to_i
  end

  def same_meet_stats_for(row)
    key = same_meet_key(row)
    return { count: 0, rank_sum: 0, prev_day_rank: 0 } if key.empty?

    @same_meet_stats[[key, row["player_name"]]] ||= { count: 0, rank_sum: 0, prev_day_rank: 0 }
  end

  def update_same_meet_stats(row, rank)
    key = same_meet_key(row)
    return if key.empty?

    st = same_meet_stats_for(row)
    st[:count] += 1
    st[:rank_sum] += rank
    st[:prev_day_rank] = rank
  end

  def ratio(num, den)
    return "0.0" if den.zero?

    format("%.6f", num.to_f / den)
  end

  def avg_rank(stats)
    return "0.0" if stats[:count].zero?

    format("%.6f", stats[:rank_sum].to_f / stats[:count])
  end

  def avg_rank_f(stats)
    return 999.9 if stats[:count].zero?

    stats[:rank_sum].to_f / stats[:count]
  end

  def same_meet_avg_rank(stats)
    return "0.0" if stats[:count].zero?

    format("%.6f", stats[:rank_sum].to_f / stats[:count])
  end

  def same_meet_avg_rank_f(stats)
    return 999.9 if stats[:count].zero?

    stats[:rank_sum].to_f / stats[:count]
  end

  def same_meet_prev_day_rank_f(stats)
    return 999.9 if stats[:prev_day_rank].to_i <= 0

    stats[:prev_day_rank].to_f
  end

  def same_meet_prev_day_rank_inv_f(stats)
    rank = stats[:prev_day_rank].to_i
    return 0.0 if rank <= 0

    1.0 / rank
  end

  def smoothed_rate(num, den, prior, strength)
    GK::FeatureEngineCommon.smoothed_rate(num, den, prior, strength)
  end

  def recent_rate_smoothed_f(stats, threshold_rank, window, prior, strength)
    GK::FeatureEngineCommon.recent_rate_smoothed_f(stats, threshold_rank, window, prior, strength)
  end

  def global_win_rate_prior
    return DEFAULT_WIN_PRIOR if @global_entries.zero?

    @global_wins.to_f / @global_entries
  end

  def global_top3_rate_prior
    return DEFAULT_TOP3_PRIOR if @global_entries.zero?

    @global_top3.to_f / @global_entries
  end

  def update_global_stats(rank)
    @global_entries += 1
    @global_wins += 1 if rank == 1
    @global_top3 += 1 if rank <= 3
  end

  def pair_context(player_name, race_rows, player_top3_prior, global_top3_prior)
    others = race_rows.map { |r| r["player_name"].to_s }.uniq.reject { |n| n == player_name }
    return { count_total: 0.0, i_top3_rate_avg: 0.0, both_top3_rate_avg: 0.0 } if others.empty?

    counts = []
    i_rates = []
    both_rates = []
    others.each do |other|
      st = pair_stats(player_name, other)
      counts << st[:count].to_f
      other_stats = stats_for(other)
      other_prior = smoothed_rate(other_stats[:top3_count], other_stats[:count], global_top3_prior, PLAYER_PRIOR_STRENGTH)
      i_rates << smoothed_rate(st[:top3_counts][player_name], st[:count], player_top3_prior, PAIR_PRIOR_STRENGTH)
      both_prior = player_top3_prior * other_prior
      both_rates << smoothed_rate(st[:both_top3_count], st[:count], both_prior, PAIR_PRIOR_STRENGTH)
    end
    {
      count_total: counts.sum,
      i_top3_rate_avg: i_rates.sum / i_rates.size,
      both_top3_rate_avg: both_rates.sum / both_rates.size
    }
  end

  def triplet_context(player_name, race_rows, player_top3_prior, global_top3_prior)
    others = race_rows.map { |r| r["player_name"].to_s }.uniq.reject { |n| n == player_name }
    combos = others.combination(2).to_a
    return { count_total: 0.0, i_top3_rate_avg: 0.0, all_top3_rate_avg: 0.0 } if combos.empty?

    counts = []
    i_rates = []
    all_rates = []
    combos.each do |a, b|
      st = triplet_stats(player_name, a, b)
      counts << st[:count].to_f
      a_stats = stats_for(a)
      b_stats = stats_for(b)
      a_prior = smoothed_rate(a_stats[:top3_count], a_stats[:count], global_top3_prior, PLAYER_PRIOR_STRENGTH)
      b_prior = smoothed_rate(b_stats[:top3_count], b_stats[:count], global_top3_prior, PLAYER_PRIOR_STRENGTH)
      i_rates << smoothed_rate(st[:top3_counts][player_name], st[:count], player_top3_prior, TRIPLET_PRIOR_STRENGTH)
      all_prior = player_top3_prior * a_prior * b_prior
      all_rates << smoothed_rate(st[:all_top3_count], st[:count], all_prior, TRIPLET_PRIOR_STRENGTH)
    end
    {
      count_total: counts.sum,
      i_top3_rate_avg: i_rates.sum / i_rates.size,
      all_top3_rate_avg: all_rates.sum / all_rates.size
    }
  end

  def pair_stats(a, b)
    key = [a.to_s, b.to_s].sort
    @pair_stats[key] ||= { count: 0, both_top3_count: 0, top3_counts: Hash.new(0) }
  end

  def triplet_stats(a, b, c)
    key = [a.to_s, b.to_s, c.to_s].sort
    @triplet_stats[key] ||= { count: 0, all_top3_count: 0, top3_counts: Hash.new(0) }
  end

  def update_pair_triplet_stats(race_rows)
    participants = race_rows.map { |r| r["player_name"].to_s }.uniq
    top3_map = race_rows.each_with_object({}) do |r, h|
      h[r["player_name"].to_s] = r["rank"].to_i <= 3
    end

    participants.combination(2) do |a, b|
      st = pair_stats(a, b)
      st[:count] += 1
      st[:top3_counts][a] += 1 if top3_map[a]
      st[:top3_counts][b] += 1 if top3_map[b]
      st[:both_top3_count] += 1 if top3_map[a] && top3_map[b]
    end

    participants.combination(3) do |a, b, c|
      st = triplet_stats(a, b, c)
      st[:count] += 1
      st[:top3_counts][a] += 1 if top3_map[a]
      st[:top3_counts][b] += 1 if top3_map[b]
      st[:top3_counts][c] += 1 if top3_map[c]
      st[:all_top3_count] += 1 if top3_map[a] && top3_map[b] && top3_map[c]
    end
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

  def recent_rate_f(stats, threshold_rank, window)
    recent = stats[:recent_ranks].first(window)
    return 0.0 if recent.empty?

    recent.count { |rank| rank <= threshold_rank }.to_f / recent.size
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
    GK::HtmlUtils.parse_racecard_entries(html).each_with_object({}) do |entry, out|
      out[entry[:car_number]] = {
        mark_symbol: entry[:mark_symbol],
        leg_style: entry[:leg_style]
      }
    end
  end

  def parse_2shatan_odds(html)
    GK::HtmlUtils.parse_2shatan_odds(html)
  end

  def mark_from_raw_cells(raw_cells)
    token = raw_cells.to_s.split("|").first.to_s.strip
    return token if token.match?(/\A[◎○▲△×注]\z/)

    ""
  end

  def mark_score(mark_symbol)
    GK::FeatureEngineCommon.mark_score(mark_symbol)
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

if __FILE__ == $PROGRAM_NAME
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
end
