CREATE OR REPLACE TEMP VIEW staging_raw_results AS
SELECT
  CAST(race_date AS DATE) AS race_date,
  venue,
  CAST(race_number AS INTEGER) AS race_number,
  racedetail_id,
  player_name,
  CAST(car_number AS INTEGER) AS car_number,
  CAST(rank AS INTEGER) AS rank,
  result_status,
  COALESCE(raw_cells, '') AS raw_cells
FROM read_parquet('{{raw_results_glob}}');
