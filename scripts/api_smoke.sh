#!/usr/bin/env bash
set -euo pipefail

base_url="${API_BASE_URL:-http://127.0.0.1:4567}"
work_dir="tmp/api-smoke"
mkdir -p "${work_dir}"

curl -fsS "${base_url}/health" >/dev/null

curl -sS -X POST "${base_url}/predict" \
  -H 'Content-Type: application/json' \
  --data @docs/api/request-examples/predict-missing-url.json > "${work_dir}/missing-url.json"

curl -sS -X POST "${base_url}/predict" \
  -H 'Content-Type: application/json' \
  --data @docs/api/request-examples/predict-invalid-url.json > "${work_dir}/invalid-url.json"

docker run --rm -v "$PWD:/app" -w /app gk-yosoku ruby -rjson -rjson-schema -e '
def parse(path)
  JSON.parse(File.read(path))
end

success_schema = JSON.parse(File.read("docs/api/predict-success.schema.json"))
error_schema = JSON.parse(File.read("docs/api/predict-error.schema.json"))
success = parse("docs/api/response-examples/predict-success.sample.json")
missing = parse("tmp/api-smoke/missing-url.json")
invalid = parse("tmp/api-smoke/invalid-url.json")

raise "success schema validation failed" unless JSON::Validator.fully_validate(success_schema, success).empty?
raise "missing-url schema validation failed" unless JSON::Validator.fully_validate(error_schema, missing).empty?
raise "invalid-url schema validation failed" unless JSON::Validator.fully_validate(error_schema, invalid).empty?
raise "missing-url code mismatch" unless missing["code"] == "invalid_request"
raise "invalid-url code mismatch" unless invalid["code"] == "predict_failed"

puts "api smoke passed"
'
