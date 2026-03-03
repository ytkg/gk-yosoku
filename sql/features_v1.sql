COPY (
  WITH today AS (
    SELECT *
    FROM staging_raw_results
    WHERE race_date = DATE '{{target_date}}'
      AND result_status = 'normal'
      AND rank BETWEEN 1 AND 7
  ),
  hist AS (
    SELECT
      t.*,
      COUNT(h.rank) AS hist_races,
      COALESCE(SUM(CASE WHEN h.rank = 1 THEN 1 ELSE 0 END), 0) AS hist_wins,
      COALESCE(SUM(CASE WHEN h.rank <= 3 THEN 1 ELSE 0 END), 0) AS hist_top3
    FROM today t
    LEFT JOIN staging_raw_results h
      ON h.player_name = t.player_name
     AND h.race_date < t.race_date
     AND h.result_status = 'normal'
     AND h.rank BETWEEN 1 AND 7
    GROUP BY
      t.race_date, t.venue, t.race_number, t.racedetail_id, t.player_name, t.car_number, t.rank, t.result_status, t.raw_cells
  ),
  base AS (
    SELECT
      STRFTIME(race_date, '%Y-%m-%d') || '-' || venue || '-' || LPAD(CAST(race_number AS VARCHAR), 2, '0') AS race_id,
      STRFTIME(race_date, '%Y-%m-%d') AS race_date,
      venue,
      CAST(race_number AS VARCHAR) AS race_number,
      racedetail_id,
      player_name,
      CAST(car_number AS VARCHAR) AS car_number,
      CAST(rank AS VARCHAR) AS rank,
      CASE WHEN rank = 1 THEN '1' ELSE '0' END AS top1,
      CASE WHEN rank <= 3 THEN '1' ELSE '0' END AS top3,
      CAST(hist_races AS VARCHAR) AS hist_races,
      CASE WHEN hist_races = 0 THEN '0.000000' ELSE FORMAT('%.6f', CAST(hist_wins AS DOUBLE) / CAST(hist_races AS DOUBLE)) END AS hist_win_rate,
      CASE WHEN hist_races = 0 THEN '0.000000' ELSE FORMAT('%.6f', CAST(hist_top3 AS DOUBLE) / CAST(hist_races AS DOUBLE)) END AS hist_top3_rate,
      CASE WHEN hist_races = 0 THEN '0.000000' ELSE FORMAT('%.6f', 4.0) END AS hist_avg_rank,
      '0' AS hist_last_rank,
      '0.000000' AS hist_recent3_weighted_avg_rank,
      '0.000000' AS hist_recent3_win_rate,
      '0.000000' AS hist_recent3_top3_rate,
      '0.000000' AS recent3_vs_hist_top3_delta,
      '0.000000' AS hist_recent5_weighted_avg_rank,
      '0.000000' AS hist_recent5_win_rate,
      '0.000000' AS hist_recent5_top3_rate,
      '-1' AS hist_days_since_last,
      '0' AS same_meet_day_number,
      '0' AS same_meet_prev_day_exists,
      '0' AS same_meet_prev_day_rank,
      '0' AS same_meet_prev_day_top1,
      '0' AS same_meet_prev_day_top3,
      '0' AS same_meet_races,
      '0.000000' AS same_meet_avg_rank,
      '0.000000' AS same_meet_prev_day_rank_inv,
      '0.000000' AS same_meet_recent3_synergy,
      '0.000000' AS pair_hist_count_total,
      '0.000000' AS pair_hist_i_top3_rate_avg,
      '0.000000' AS pair_hist_both_top3_rate_avg,
      '0.000000' AS triplet_hist_count_total,
      '0.000000' AS triplet_hist_i_top3_rate_avg,
      '0.000000' AS triplet_hist_all_top3_rate_avg,
      REGEXP_EXTRACT(raw_cells, '(◎|○|▲|△|×|注)', 1) AS mark_symbol,
      '' AS leg_style,
      '0.0' AS mark_score,
      '9999.900000' AS odds_2shatan_min_first,
      CAST(COUNT(*) OVER (PARTITION BY race_date, venue, race_number) AS VARCHAR) AS race_field_size
    FROM hist
  ),
  ranked AS (
    SELECT
      *,
      CAST(DENSE_RANK() OVER (PARTITION BY race_id ORDER BY CAST(hist_avg_rank AS DOUBLE) ASC, CAST(car_number AS INTEGER) ASC) AS VARCHAR) AS race_rel_hist_avg_rank_rank,
      CAST(DENSE_RANK() OVER (PARTITION BY race_id ORDER BY CAST(hist_recent3_top3_rate AS DOUBLE) DESC, CAST(car_number AS INTEGER) ASC) AS VARCHAR) AS race_rel_hist_recent3_top3_rate_rank,
      CAST(DENSE_RANK() OVER (PARTITION BY race_id ORDER BY CAST(hist_recent5_top3_rate AS DOUBLE) DESC, CAST(car_number AS INTEGER) ASC) AS VARCHAR) AS race_rel_hist_recent5_top3_rate_rank,
      CAST(DENSE_RANK() OVER (PARTITION BY race_id ORDER BY CAST(same_meet_prev_day_rank AS INTEGER) ASC, CAST(car_number AS INTEGER) ASC) AS VARCHAR) AS race_rel_same_meet_prev_day_rank,
      CAST(DENSE_RANK() OVER (PARTITION BY race_id ORDER BY CAST(same_meet_avg_rank AS DOUBLE) ASC, CAST(car_number AS INTEGER) ASC) AS VARCHAR) AS race_rel_same_meet_avg_rank_rank,
      CAST(DENSE_RANK() OVER (PARTITION BY race_id ORDER BY CAST(same_meet_recent3_synergy AS DOUBLE) DESC, CAST(car_number AS INTEGER) ASC) AS VARCHAR) AS race_rel_same_meet_recent3_synergy_rank,
      CAST(DENSE_RANK() OVER (PARTITION BY race_id ORDER BY CAST(pair_hist_i_top3_rate_avg AS DOUBLE) DESC, CAST(car_number AS INTEGER) ASC) AS VARCHAR) AS race_rel_pair_i_top3_rate_rank,
      CAST(DENSE_RANK() OVER (PARTITION BY race_id ORDER BY CAST(triplet_hist_i_top3_rate_avg AS DOUBLE) DESC, CAST(car_number AS INTEGER) ASC) AS VARCHAR) AS race_rel_triplet_i_top3_rate_rank,
      CAST(DENSE_RANK() OVER (PARTITION BY race_id ORDER BY CAST(hist_win_rate AS DOUBLE) DESC, CAST(car_number AS INTEGER) ASC) AS VARCHAR) AS race_rel_hist_win_rate_rank,
      CAST(DENSE_RANK() OVER (PARTITION BY race_id ORDER BY CAST(hist_top3_rate AS DOUBLE) DESC, CAST(car_number AS INTEGER) ASC) AS VARCHAR) AS race_rel_hist_top3_rate_rank,
      CAST(DENSE_RANK() OVER (PARTITION BY race_id ORDER BY CAST(mark_score AS DOUBLE) DESC, CAST(car_number AS INTEGER) ASC) AS VARCHAR) AS race_rel_mark_score_rank,
      CAST(DENSE_RANK() OVER (PARTITION BY race_id ORDER BY CAST(odds_2shatan_min_first AS DOUBLE) ASC, CAST(car_number AS INTEGER) ASC) AS VARCHAR) AS race_rel_odds_2shatan_rank
    FROM base
  )
  SELECT *
  FROM ranked
  ORDER BY race_date, venue, CAST(race_number AS INTEGER), CAST(car_number AS INTEGER)
) TO '{{out_csv}}' (HEADER, DELIMITER ',');
