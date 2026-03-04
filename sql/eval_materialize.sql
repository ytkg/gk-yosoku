COPY (
  SELECT *
  FROM read_parquet('{{features_glob}}')
  WHERE CAST(race_date AS DATE) BETWEEN DATE '{{from_date}}'
                                  AND DATE '{{to_date}}'
  ORDER BY race_date, venue, CAST(race_number AS INTEGER), CAST(car_number AS INTEGER)
) TO '{{out_parquet}}' (FORMAT PARQUET, COMPRESSION ZSTD);
