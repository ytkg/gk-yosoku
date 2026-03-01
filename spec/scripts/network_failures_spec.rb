# frozen_string_literal: true

require "spec_helper"

RSpec.describe "network failures" do
  it "dump_race_html_json.rb: 接続失敗時は異常終了する" do
    Dir.mktmpdir("spec-network-dump-") do |tmp|
      _out, err, st = run_cmd(
        "ruby", "scripts/dump_race_html_json.rb",
        "--url", "http://127.0.0.1:1/toride/racedetail/2320260225030004/",
        "--no-cache",
        "--cache-dir", tmp
      )
      expect(st.success?).to be(false)
      expect(err).to match(/Failed to open TCP connection|Connection refused|getaddrinfo/)
    end
  end

  it "predict_race.rb: 接続失敗時は異常終了する" do
    Dir.mktmpdir("spec-network-predict-") do |tmp|
      bin_dir = File.join(tmp, "bin")
      create_fake_lightgbm(bin_dir)
      env = { "PATH" => "#{bin_dir}:#{ENV.fetch('PATH', '')}" }

      _out, err, st = run_cmd(
        "ruby", "scripts/predict_race.rb",
        "--url", "http://127.0.0.1:1/toride/racedetail/2320260225030004/",
        "--cache-dir", File.join(tmp, "cache"),
        "--no-cache",
        env: env
      )
      expect(st.success?).to be(false)
      expect(err).to match(/Failed to open TCP connection|Connection refused|getaddrinfo/)
    end
  end
end
