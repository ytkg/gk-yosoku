# frozen_string_literal: true

require "spec_helper"

RSpec.describe "dump_race_html_json.rb" do
  it "HTMLファイルからJSONを出力できる" do
    Dir.mktmpdir("spec-dump-html-") do |tmp|
      html_path = File.join(tmp, "race.html")
      html = <<~HTML
        <table class="racecard_table">
          <tr><th>脚<br>質</th><th class="num">車番</th></tr>
          <tr class="n1">
            <td class="num"><span>1</span></td>
            <td class="rider bdr_r">選手A<br>東京</td>
            <td><span class="icon_t1">◎</span></td>
            <td class="bdr_r">逃</td>
          </tr>
        </table>
      HTML
      File.write(html_path, html)

      out_json = File.join(tmp, "out.json")
      _out, err, st = run_cmd(
        "ruby", "scripts/dump_race_html_json.rb",
        "--html-file", html_path,
        "--mode", "full",
        "--out", out_json
      )
      expect(st.success?).to be(true), err

      parsed = JSON.parse(File.read(out_json, encoding: "UTF-8"))
      expect(parsed["entries"].size).to eq(1)
      expect(parsed["entries"].first["player_name"]).to eq("選手A")
      expect(parsed["tables"]).not_to be_empty
    end
  end

  it "--html-file と --url の同時指定はエラーになる" do
    Dir.mktmpdir("spec-dump-conflict-") do |tmp|
      html_path = File.join(tmp, "race.html")
      File.write(html_path, "<html></html>")

      _out, err, st = run_cmd(
        "ruby", "scripts/dump_race_html_json.rb",
        "--html-file", html_path,
        "--url", "https://keirin.kdreams.jp/toride/racedetail/2320260225030004/"
      )
      expect(st.success?).to be(false)
      expect(err).to include("--html-file と --url はどちらか片方のみ指定してください")
    end
  end

  it "mode不正はエラーになる" do
    Dir.mktmpdir("spec-dump-mode-") do |tmp|
      html_path = File.join(tmp, "race.html")
      File.write(html_path, "<html></html>")

      _out, err, st = run_cmd(
        "ruby", "scripts/dump_race_html_json.rb",
        "--html-file", html_path,
        "--mode", "invalid"
      )
      expect(st.success?).to be(false)
      expect(err).to include("--mode は basic/full を指定してください")
    end
  end
end
