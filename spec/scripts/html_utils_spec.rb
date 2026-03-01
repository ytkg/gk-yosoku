# frozen_string_literal: true

require "spec_helper"
require_relative "../../scripts/lib/html_utils"

RSpec.describe GK::HtmlUtils do
  it "race detail HTMLをJSON向け構造に変換できる" do
    html = <<~HTML
      <table class="racecard_table">
        <tr><th>脚<br>質</th><th class="num">車番</th></tr>
        <tr class="n1">
          <td class="num"><span>1</span></td>
          <td class="rider bdr_r">選手A<br>東京</td>
          <td><span class="icon_t1">◎</span></td>
          <td class="bdr_r">逃</td>
        </tr>
        <tr class="n2">
          <td class="num"><span>2</span></td>
          <td class="rider bdr_r">選手B<br>大阪</td>
          <td><span class="icon_t1">○</span></td>
          <td class="bdr_r">両</td>
        </tr>
      </table>
      <a href="https://example.com/race/1">詳細</a>

      <div class="odds_contents" id="JS_ODDSCONTENTS_2shatan">
        <table class="odds_table">
          <tr><th rowspan="2">x</th><th class="n1">1</th><th class="n2">2</th><th rowspan="2">x</th></tr>
          <tr><th class="n2">2</th><td>2.3</td><td>-</td><th class="n2">2</th></tr>
          <tr><th class="n1">1</th><td>-</td><td>4.5</td><th class="n1">1</th></tr>
        </table>
        <span class="num">1-2</span><span class="odds">2.3</span>
      </div><!-- 2車単 End -->

      <div class="odds_contents" id="JS_ODDSCONTENTS_3rentan">
        <table class="odds_table bt5">
          <th class="n1">1</th>
          <tr><th rowspan="2">x</th><th class="n2">2</th><th class="n3">3</th><th rowspan="2">x</th></tr>
          <tr><th class="n3">3</th><td>5.0</td><td>-</td><th class="n3">3</th></tr>
          <tr><th class="n2">2</th><td>-</td><td>6.0</td><th class="n2">2</th></tr>
        </table>
        <span class="num">1-2-3</span><span class="odds">5.0</span>
      </div><!-- 3連単 End -->

      <table class="result_table">
        <tr><td>1</td><td>1</td><td>選手A</td></tr>
      </table>
    HTML

    parsed = described_class.parse_race_detail_json(html)
    full = described_class.parse_race_detail_full_json(html)

    expect(parsed["entries"].size).to eq(2)
    expect(parsed["entries"].first["car_number"]).to eq(1)
    expect(parsed["entries"].first["player_name"]).to eq("選手A")
    expect(parsed.dig("odds", "exacta_min_by_first", "1")).to eq(2.3)
    expect(parsed.dig("odds", "exacta_pairs", "1-2")).to eq(2.3)
    expect(parsed.dig("odds", "trifecta_pairs", "1-2-3")).to eq(5.0)
    expect(parsed.dig("odds", "popular_exacta").first).to include("first_car_number" => 1, "second_car_number" => 2)
    expect(parsed.dig("odds", "popular_trifecta").first).to include("first_car_number" => 1, "second_car_number" => 2, "third_car_number" => 3)
    expect(full["tables"].size).to be >= 2
    expect(full["links"]).to include(include("href" => "https://example.com/race/1", "text" => "詳細"))
    expect(full["result_rows"]).to eq([["1", "1", "選手A"]])
  end
end
