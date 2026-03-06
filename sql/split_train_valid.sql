CREATE OR REPLACE TEMP VIEW features_all AS
SELECT *
FROM read_parquet('{{features_glob}}');

CREATE OR REPLACE TEMP VIEW features_filtered AS
SELECT *
FROM features_all
WHERE CAST(race_date AS DATE) BETWEEN DATE '{{from_date}}'
                                AND DATE '{{to_date}}';

{{train_csv_copy_sql}}

{{valid_csv_copy_sql}}

COPY (
  SELECT *
  FROM features_filtered
  WHERE CAST(race_date AS DATE) <= DATE '{{train_to}}'
) TO '{{train_parquet}}' (FORMAT PARQUET, COMPRESSION ZSTD);

COPY (
  SELECT *
  FROM features_filtered
  WHERE CAST(race_date AS DATE) > DATE '{{train_to}}'
) TO '{{valid_parquet}}' (FORMAT PARQUET, COMPRESSION ZSTD);
