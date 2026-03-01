# frozen_string_literal: true

require "spec_helper"

RSpec.describe "collect_data.rb" do
  it "cache HTMLからCSVを作る" do
    Dir.mktmpdir("spec-collect-") do |tmp|
      raw_dir = File.join(tmp, "raw")
      raw_html_dir = File.join(tmp, "raw_html")
      date = "2026-02-26"
      ymd = "20260226"
      FileUtils.mkdir_p(File.join(raw_html_dir, "results", ymd))

      show_url = "https://keirin.kdreams.jp/toride/racedetail/2320260226010001/?pageType=showResult"
      kaisai_html = <<~HTML
        <div class="kaisai-list" id="k1">
          <div class="kaisai-program_table">
            <table>
              <tr><td class="program_bg_7">girls</td></tr>
              <tr><td><a href="#{show_url}">result</a></td></tr>
            </table>
          </div>
        </div>
      HTML
      File.write(File.join(raw_html_dir, "kaisai_#{ymd}.html"), kaisai_html)

      result_html = <<~HTML
        <table class="result_table">
          <tr><td>x</td><td>1</td><td>1</td><td>選手A</td></tr>
          <tr><td>x</td><td>2</td><td>2</td><td>選手B</td></tr>
          <tr><td>x</td><td>落</td><td>3</td><td>選手C</td></tr>
        </table>
      HTML
      hash = Digest::SHA1.hexdigest(show_url)
      File.write(File.join(raw_html_dir, "results", ymd, "result_#{hash}.html"), result_html)

      _out, err, status = run_cmd(
        "ruby", "scripts/collect_data.rb",
        "--from-date", date,
        "--to-date", date,
        "--raw-dir", raw_dir,
        "--raw-html-dir", raw_html_dir,
        "--cache",
        "--sleep", "0"
      )
      expect(status.success?).to be(true), err

      races = CSV.read(File.join(raw_dir, "girls_races_#{ymd}.csv"), headers: true)
      results = CSV.read(File.join(raw_dir, "girls_results_#{ymd}.csv"), headers: true)
      expect(races.size).to eq(1)
      expect(results.size).to eq(3)
      expect(results.map { |r| r["result_status"] }).to include("fall")
    end
  end

  it "from/to未指定ならusageで終了する" do
    _out, err, status = run_cmd("ruby", "scripts/collect_data.rb")
    expect(status.success?).to be(false)
    expect(err).to include("Usage: ruby scripts/collect_data.rb")
  end
end
