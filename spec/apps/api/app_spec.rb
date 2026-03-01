# frozen_string_literal: true

require "spec_helper"
require "json-schema"
require "rack/test"
require_relative "../../../apps/api/app"

RSpec.describe GK::PredictAPI do
  include Rack::Test::Methods

  def app
    GK::PredictAPI.new
  end

  def load_schema(path)
    JSON.parse(File.read(path))
  end

  it "GET /health は healthy を返す" do
    get "/health", {}, { "HTTP_HOST" => "localhost" }

    expect(last_response.status).to eq(200)
    body = JSON.parse(last_response.body)
    expect(body["code"]).to eq("ok")
    expect(body["message"]).to eq("healthy")
    expect(body.dig("detail", "service")).to eq("predict-api")
  end

  it "POST /predict 正常系は code=ok を返す" do
    stdout = JSON.generate(
      "race" => {
        "race_id" => "2026-02-25-toride-01",
        "race_date" => "2026-02-25",
        "venue" => "toride",
        "race_number" => 1,
        "racedetail_id" => "26202602250100"
      },
      "entries" => [
        {
          "car_number" => 1,
          "player_name" => "A",
          "mark_symbol" => "◎",
          "leg_style" => "逃",
          "odds_2shatan_min_first" => 2.2
        }
      ],
      "rankings" => [{ "rank" => 1, "car_number" => 1, "player_name" => "A", "score_top1" => 0.9, "score_top3" => 0.95 }],
      "confidence" => { "gap" => 0.1, "threshold" => 0.05, "action" => "bet" },
      "exotics" => { "decision" => "bet", "exacta" => { "rows" => [] }, "trifecta" => { "rows" => [] } }
    )
    allow(Open3).to receive(:capture3).and_return([stdout, "", instance_double(Process::Status, success?: true)])

    post "/predict", JSON.generate("url" => "https://example.com/racedetail/0000000000000000"), { "CONTENT_TYPE" => "application/json", "HTTP_HOST" => "localhost" }

    expect(last_response.status).to eq(200)
    body = JSON.parse(last_response.body)
    expect(body["code"]).to eq("ok")
    expect(body.dig("detail", "race", "race_id")).to eq("2026-02-25-toride-01")
    expect(body.dig("detail", "rankings", 0, "car_number")).to eq(1)
    schema = load_schema(File.join(__dir__, "../../../docs/api/predict-success.schema.json"))
    errors = JSON::Validator.fully_validate(schema, body)
    expect(errors).to eq([])
  end

  it "POST /predict 異常系は code/message/detail 形式で返す" do
    status = instance_double(Process::Status, success?: false, exitstatus: 1)
    allow(Open3).to receive(:capture3).and_return(["", "boom", status])

    post "/predict", JSON.generate("url" => "https://example.com/racedetail/0000000000000000"), { "CONTENT_TYPE" => "application/json", "HTTP_HOST" => "localhost" }

    expect(last_response.status).to eq(422)
    body = JSON.parse(last_response.body)
    expect(body["code"]).to eq("predict_failed")
    expect(body["message"]).to be_a(String)
    expect(body["detail"]).to include("stderr", "exit_status")
    schema = load_schema(File.join(__dir__, "../../../docs/api/predict-error.schema.json"))
    errors = JSON::Validator.fully_validate(schema, body)
    expect(errors).to eq([])
  end

  it "url 欠落時は invalid_request を返す" do
    post "/predict", JSON.generate({}), { "CONTENT_TYPE" => "application/json", "HTTP_HOST" => "localhost" }

    expect(last_response.status).to eq(422)
    body = JSON.parse(last_response.body)
    expect(body["code"]).to eq("invalid_request")
    expect(body["detail"]).to include("field" => "url")
  end

  it "POST /predict タイムアウト時は predict_timeout を返す" do
    allow_any_instance_of(GK::PredictAPI).to receive(:timeout_seconds).and_return(0.01)
    allow(Open3).to receive(:capture3) { sleep 0.05 }

    post "/predict", JSON.generate("url" => "https://example.com/racedetail/0000000000000000"), { "CONTENT_TYPE" => "application/json", "HTTP_HOST" => "localhost" }

    expect(last_response.status).to eq(504)
    body = JSON.parse(last_response.body)
    expect(body["code"]).to eq("predict_timeout")
    expect(body["detail"]).to include("timeout_seconds")
  end
end
