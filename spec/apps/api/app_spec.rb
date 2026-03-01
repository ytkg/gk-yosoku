# frozen_string_literal: true

require "spec_helper"
require "rack/test"
require_relative "../../../apps/api/app"

RSpec.describe GK::PredictAPI do
  include Rack::Test::Methods

  def app
    GK::PredictAPI.new
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
    allow(Open3).to receive(:capture3).and_return(["rankings\n", "", instance_double(Process::Status, success?: true)])

    post "/predict", JSON.generate("url" => "https://example.com/racedetail/0000000000000000"), { "CONTENT_TYPE" => "application/json", "HTTP_HOST" => "localhost" }

    expect(last_response.status).to eq(200)
    body = JSON.parse(last_response.body)
    expect(body["code"]).to eq("ok")
    expect(body.dig("detail", "stdout")).to include("rankings")
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
