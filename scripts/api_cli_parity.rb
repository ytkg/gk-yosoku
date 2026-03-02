#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require "optparse"
require "net/http"
require "uri"
require_relative "lib/predict_command_builder"

options = {
  payload: "docs/api/fixtures/parity_request.json",
  api_url: "http://127.0.0.1:4567/predict",
  image: "gk-yosoku"
}

OptionParser.new do |opts|
  opts.on("--payload PATH", "payload json path") { |v| options[:payload] = v }
  opts.on("--api-url URL", "predict API URL") { |v| options[:api_url] = v }
  opts.on("--image NAME", "docker image name") { |v| options[:image] = v }
end.parse!

def deep_diff(a, b, path = "$")
  return [] if a == b

  if a.is_a?(Hash) && b.is_a?(Hash)
    keys = (a.keys + b.keys).uniq.sort
    return keys.flat_map { |k| deep_diff(a[k], b[k], "#{path}.#{k}") }
  end
  if a.is_a?(Array) && b.is_a?(Array)
    max = [a.size, b.size].max
    return (0...max).flat_map { |i| deep_diff(a[i], b[i], "#{path}[#{i}]") }
  end

  ["#{path}: expected=#{a.inspect} actual=#{b.inspect}"]
end

def parse_embedded_json(text)
  src = text.to_s.force_encoding("UTF-8")
  starts = []
  src.each_char.with_index { |ch, idx| starts << idx if ch == "{" }
  starts.each do |idx|
    candidate = src[idx..]
    begin
      return JSON.parse(candidate)
    rescue JSON::ParserError
      next
    end
  end
  raise JSON::ParserError, "no valid json object found in output"
end

payload = JSON.parse(File.read(options[:payload], encoding: "UTF-8"))
cli_args = GK::PredictCommandBuilder.build(payload) + ["--output-json"]
cli_cmd = ["docker", "run", "--rm", "-v", "#{Dir.pwd}:/app", "-w", "/app", options[:image], "ruby", "scripts/predict_race.rb", *cli_args]

cli_out, cli_err, cli_status = Open3.capture3(*cli_cmd)
abort("cli command failed:\n#{cli_err}\n#{cli_out}") unless cli_status.success?

cli_json = parse_embedded_json(cli_out)

uri = URI.parse(options[:api_url])
http = Net::HTTP.new(uri.host, uri.port)
http.use_ssl = uri.scheme == "https"
req = Net::HTTP::Post.new(uri.request_uri)
req["Content-Type"] = "application/json"
req.body = JSON.generate(payload)
res = http.request(req)
api_body = JSON.parse(res.body.to_s.force_encoding("UTF-8"))

unless res.code.to_i == 200 && api_body["code"] == "ok"
  abort("api request failed: status=#{res.code} body=#{res.body}")
end

api_json = api_body.fetch("detail")
diffs = deep_diff(cli_json, api_json)
if diffs.empty?
  puts "api-cli parity passed"
  exit 0
end

warn "api-cli parity mismatch:"
warn diffs.first(30).join("\n")
exit 1
