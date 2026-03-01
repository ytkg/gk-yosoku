# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"
require "sinatra/base"
require "timeout"
require_relative "../../scripts/lib/predict_command_builder"

module GK
  class PredictAPI < Sinatra::Base
    configure do
      set :show_exceptions, false
      set :protection, false
    end

    before do
      content_type :json
    end

    get "/health" do
      status 200
      JSON.generate(
        "code" => "ok",
        "message" => "healthy",
        "detail" => {
          "service" => "predict-api"
        }
      )
    end

    post "/predict" do
      payload = parse_json_body(request.body.read)
      url = payload["url"].to_s
      if url.empty?
        status 422
        return json_error("invalid_request", "url is required", { "field" => "url" })
      end

      cmd = [RbConfig.ruby, "scripts/predict_race.rb", *GK::PredictCommandBuilder.build(payload)]
      cmd << "--output-json"
      timeout_sec = timeout_seconds
      out, err, st = Timeout.timeout(timeout_sec) { Open3.capture3(*cmd) }

      if st.success?
        parsed = parse_predict_output(out)
        status 200
        return JSON.generate(
          "code" => "ok",
          "message" => "prediction completed",
          "detail" => parsed
        )
      end

      status 422
      json_error(
        "predict_failed",
        "prediction command failed",
        {
          "stdout" => out,
          "stderr" => err,
          "exit_status" => st.exitstatus
        }
      )
    rescue Timeout::Error
      status 504
      json_error(
        "predict_timeout",
        "prediction command timed out",
        {
          "timeout_seconds" => timeout_sec
        }
      )
    end

    error JSON::ParserError do
      status 400
      json_error("invalid_json", "request body must be valid JSON", {})
    end

    error StandardError do
      status 500
      json_error("internal_error", env["sinatra.error"].message, {})
    end

    run! if app_file == $PROGRAM_NAME

    private

    def parse_json_body(raw)
      return {} if raw.to_s.strip.empty?

      JSON.parse(raw)
    end

    def json_error(code, message, detail)
      JSON.generate(
        "code" => code,
        "message" => message,
        "detail" => detail
      )
    end

    def timeout_seconds
      raw = ENV.fetch("GK_PREDICT_TIMEOUT_SEC", "30")
      value = raw.to_i
      value.positive? ? value : 30
    end

    def parse_predict_output(out)
      JSON.parse(out)
    rescue JSON::ParserError
      raise "predict output is not valid JSON"
    end
  end
end
