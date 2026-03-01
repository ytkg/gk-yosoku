# frozen_string_literal: true

module CliTestHelpers
  REPO_ROOT = File.expand_path("../..", __dir__)

  def run_cmd(*args, env: {}, chdir: REPO_ROOT)
    Open3.capture3(env, *args, chdir: chdir)
  end

  def write_csv(path, headers, rows)
    FileUtils.mkdir_p(File.dirname(path))
    CSV.open(path, "w", write_headers: true, headers: headers) do |csv|
      rows.each { |r| csv << headers.map { |h| r[h] } }
    end
  end

  def create_fake_lightgbm(bin_dir)
    FileUtils.mkdir_p(bin_dir)
    path = File.join(bin_dir, "lightgbm")
    File.write(path, <<~'SCRIPT')
      #!/usr/bin/env ruby
      config_arg = ARGV.find { |a| a.start_with?("config=") }
      abort("missing config") if config_arg.nil?
      conf_path = config_arg.split("=", 2)[1]

      conf = {}
      File.readlines(conf_path, chomp: true).each do |line|
        next if line.strip.empty? || line.start_with?("#")
        k, v = line.split("=", 2)
        conf[k] = v
      end

      case conf["task"]
      when "train"
        File.write(conf.fetch("output_model"), "dummy model\n")
        puts "train ok"
      when "predict"
        rows = File.readlines(conf.fetch("data"), chomp: true).reject { |l| l.strip.empty? }
        File.open(conf.fetch("output_result"), "w") do |f|
          rows.each_with_index { |_, i| f.puts(format("%.6f", 0.9 - (i * 0.01))) }
        end
        puts "predict ok"
      else
        abort("unknown task: #{conf['task']}")
      end
    SCRIPT
    FileUtils.chmod("u+x", path)
    path
  end

  def create_fake_duckdb(bin_dir)
    FileUtils.mkdir_p(bin_dir)
    path = File.join(bin_dir, "duckdb")
    File.write(path, <<~'SCRIPT')
      #!/usr/bin/env ruby
      require "fileutils"

      _db_path = ARGV[0]
      sql = STDIN.read
      sql.scan(/TO\s+'([^']+)'/i).flatten.each do |out_path|
        FileUtils.mkdir_p(File.dirname(out_path))
        if out_path.end_with?("summary.csv")
          File.write(out_path, "csv_rows,parquet_rows,csv_only_keys,parquet_only_keys,rank_diff,top1_diff,top3_diff\n1,1,0,0,0,0,0\n")
        elsif out_path.end_with?(".csv")
          File.write(out_path, "race_id,race_date,venue,race_number,car_number,player_name,rank,top1,top3,mark_symbol,leg_style\nr1,2026-02-25,toride,1,1,A,1,1,1,◎,逃\n")
        else
          File.write(out_path, "fake parquet from duckdb\n")
        end
      end
      puts "duckdb ok"
    SCRIPT
    FileUtils.chmod("u+x", path)
    path
  end

  def feature_headers
    %w[
      race_id race_date venue race_number racedetail_id player_name car_number rank top1 top3
      hist_races hist_win_rate hist_top3_rate hist_avg_rank hist_last_rank
      hist_recent3_weighted_avg_rank hist_recent3_win_rate hist_recent3_top3_rate recent3_vs_hist_top3_delta
      hist_recent5_weighted_avg_rank hist_recent5_win_rate hist_recent5_top3_rate hist_days_since_last
      same_meet_day_number same_meet_prev_day_exists same_meet_prev_day_rank same_meet_prev_day_top1 same_meet_prev_day_top3 same_meet_races same_meet_avg_rank same_meet_prev_day_rank_inv same_meet_recent3_synergy
      pair_hist_count_total pair_hist_i_top3_rate_avg pair_hist_both_top3_rate_avg
      triplet_hist_count_total triplet_hist_i_top3_rate_avg triplet_hist_all_top3_rate_avg
      race_rel_hist_avg_rank_rank race_rel_hist_recent3_top3_rate_rank race_rel_hist_recent5_top3_rate_rank
      race_rel_same_meet_prev_day_rank race_rel_same_meet_avg_rank_rank race_rel_same_meet_recent3_synergy_rank
      race_rel_pair_i_top3_rate_rank race_rel_triplet_i_top3_rate_rank
      race_rel_hist_win_rate_rank race_rel_hist_top3_rate_rank mark_symbol leg_style
      mark_score race_rel_mark_score_rank odds_2shatan_min_first race_rel_odds_2shatan_rank race_field_size
    ]
  end

  def sample_feature_rows(date:, race_id:, racedetail_id: "2320260225010001")
    [
      { "race_id" => race_id, "race_date" => date, "venue" => "toride", "race_number" => "1", "racedetail_id" => racedetail_id,
        "player_name" => "A", "car_number" => "1", "rank" => "1", "top1" => "1", "top3" => "1",
        "hist_races" => "10", "hist_win_rate" => "0.200000", "hist_top3_rate" => "0.500000", "hist_avg_rank" => "3.200000", "hist_last_rank" => "2",
        "hist_recent3_weighted_avg_rank" => "2.400000", "hist_recent3_win_rate" => "0.333333", "hist_recent3_top3_rate" => "0.666667", "recent3_vs_hist_top3_delta" => "0.166667",
        "hist_recent5_weighted_avg_rank" => "2.800000", "hist_recent5_win_rate" => "0.200000", "hist_recent5_top3_rate" => "0.600000", "hist_days_since_last" => "3",
        "same_meet_day_number" => "2", "same_meet_prev_day_exists" => "1", "same_meet_prev_day_rank" => "1", "same_meet_prev_day_top1" => "1", "same_meet_prev_day_top3" => "1", "same_meet_races" => "1", "same_meet_avg_rank" => "1.000000", "same_meet_prev_day_rank_inv" => "1.000000", "same_meet_recent3_synergy" => "0.666667",
        "pair_hist_count_total" => "3.000000", "pair_hist_i_top3_rate_avg" => "0.666667", "pair_hist_both_top3_rate_avg" => "0.500000",
        "triplet_hist_count_total" => "1.000000", "triplet_hist_i_top3_rate_avg" => "1.000000", "triplet_hist_all_top3_rate_avg" => "0.500000",
        "race_rel_hist_avg_rank_rank" => "1", "race_rel_hist_recent3_top3_rate_rank" => "1", "race_rel_hist_recent5_top3_rate_rank" => "1",
        "race_rel_same_meet_prev_day_rank" => "1", "race_rel_same_meet_avg_rank_rank" => "1", "race_rel_same_meet_recent3_synergy_rank" => "1",
        "race_rel_pair_i_top3_rate_rank" => "1", "race_rel_triplet_i_top3_rate_rank" => "1",
        "race_rel_hist_win_rate_rank" => "1", "race_rel_hist_top3_rate_rank" => "1", "mark_symbol" => "◎", "leg_style" => "逃",
        "mark_score" => "5.0", "race_rel_mark_score_rank" => "1", "odds_2shatan_min_first" => "1.200000", "race_rel_odds_2shatan_rank" => "1", "race_field_size" => "3" },
      { "race_id" => race_id, "race_date" => date, "venue" => "toride", "race_number" => "1", "racedetail_id" => racedetail_id,
        "player_name" => "B", "car_number" => "2", "rank" => "2", "top1" => "0", "top3" => "1",
        "hist_races" => "8", "hist_win_rate" => "0.125000", "hist_top3_rate" => "0.375000", "hist_avg_rank" => "3.700000", "hist_last_rank" => "3",
        "hist_recent3_weighted_avg_rank" => "3.300000", "hist_recent3_win_rate" => "0.000000", "hist_recent3_top3_rate" => "0.333333", "recent3_vs_hist_top3_delta" => "-0.041667",
        "hist_recent5_weighted_avg_rank" => "3.100000", "hist_recent5_win_rate" => "0.000000", "hist_recent5_top3_rate" => "0.400000", "hist_days_since_last" => "5",
        "same_meet_day_number" => "2", "same_meet_prev_day_exists" => "1", "same_meet_prev_day_rank" => "2", "same_meet_prev_day_top1" => "0", "same_meet_prev_day_top3" => "1", "same_meet_races" => "1", "same_meet_avg_rank" => "2.000000", "same_meet_prev_day_rank_inv" => "0.500000", "same_meet_recent3_synergy" => "0.166667",
        "pair_hist_count_total" => "3.000000", "pair_hist_i_top3_rate_avg" => "0.333333", "pair_hist_both_top3_rate_avg" => "0.333333",
        "triplet_hist_count_total" => "1.000000", "triplet_hist_i_top3_rate_avg" => "0.500000", "triplet_hist_all_top3_rate_avg" => "0.250000",
        "race_rel_hist_avg_rank_rank" => "2", "race_rel_hist_recent3_top3_rate_rank" => "2", "race_rel_hist_recent5_top3_rate_rank" => "2",
        "race_rel_same_meet_prev_day_rank" => "2", "race_rel_same_meet_avg_rank_rank" => "2", "race_rel_same_meet_recent3_synergy_rank" => "2",
        "race_rel_pair_i_top3_rate_rank" => "2", "race_rel_triplet_i_top3_rate_rank" => "2",
        "race_rel_hist_win_rate_rank" => "2", "race_rel_hist_top3_rate_rank" => "2", "mark_symbol" => "○", "leg_style" => "両",
        "mark_score" => "4.0", "race_rel_mark_score_rank" => "2", "odds_2shatan_min_first" => "2.300000", "race_rel_odds_2shatan_rank" => "2", "race_field_size" => "3" },
      { "race_id" => race_id, "race_date" => date, "venue" => "toride", "race_number" => "1", "racedetail_id" => racedetail_id,
        "player_name" => "C", "car_number" => "3", "rank" => "3", "top1" => "0", "top3" => "1",
        "hist_races" => "6", "hist_win_rate" => "0.000000", "hist_top3_rate" => "0.166666", "hist_avg_rank" => "4.100000", "hist_last_rank" => "5",
        "hist_recent3_weighted_avg_rank" => "4.500000", "hist_recent3_win_rate" => "0.000000", "hist_recent3_top3_rate" => "0.000000", "recent3_vs_hist_top3_delta" => "-0.166666",
        "hist_recent5_weighted_avg_rank" => "4.200000", "hist_recent5_win_rate" => "0.000000", "hist_recent5_top3_rate" => "0.200000", "hist_days_since_last" => "9",
        "same_meet_day_number" => "2", "same_meet_prev_day_exists" => "1", "same_meet_prev_day_rank" => "3", "same_meet_prev_day_top1" => "0", "same_meet_prev_day_top3" => "1", "same_meet_races" => "1", "same_meet_avg_rank" => "3.000000", "same_meet_prev_day_rank_inv" => "0.333333", "same_meet_recent3_synergy" => "0.000000",
        "pair_hist_count_total" => "3.000000", "pair_hist_i_top3_rate_avg" => "0.166667", "pair_hist_both_top3_rate_avg" => "0.166667",
        "triplet_hist_count_total" => "1.000000", "triplet_hist_i_top3_rate_avg" => "0.250000", "triplet_hist_all_top3_rate_avg" => "0.125000",
        "race_rel_hist_avg_rank_rank" => "3", "race_rel_hist_recent3_top3_rate_rank" => "3", "race_rel_hist_recent5_top3_rate_rank" => "3",
        "race_rel_same_meet_prev_day_rank" => "3", "race_rel_same_meet_avg_rank_rank" => "3", "race_rel_same_meet_recent3_synergy_rank" => "3",
        "race_rel_pair_i_top3_rate_rank" => "3", "race_rel_triplet_i_top3_rate_rank" => "3",
        "race_rel_hist_win_rate_rank" => "3", "race_rel_hist_top3_rate_rank" => "3", "mark_symbol" => "▲", "leg_style" => "追",
        "mark_score" => "3.0", "race_rel_mark_score_rank" => "3", "odds_2shatan_min_first" => "5.100000", "race_rel_odds_2shatan_rank" => "3", "race_field_size" => "3" }
    ]
  end
end
