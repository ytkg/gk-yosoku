# frozen_string_literal: true

require "spec_helper"

RSpec.describe "predict_race.rb" do
  it "URL引数で予測を出せる（cache + fake lightgbm）" do
    Dir.mktmpdir("spec-predict-") do |tmp|
      bin_dir = File.join(tmp, "bin")
      create_fake_lightgbm(bin_dir)
      env = { "PATH" => "#{bin_dir}:#{ENV.fetch('PATH', '')}" }

      url = "https://keirin.kdreams.jp/toride/racedetail/2320260225030004/"
      cache_dir = File.join(tmp, "cache")
      raw_dir = File.join(tmp, "raw")
      model_dir = File.join(tmp, "models")
      FileUtils.mkdir_p(cache_dir)
      FileUtils.mkdir_p(raw_dir)
      FileUtils.mkdir_p(model_dir)

      html = <<~HTML
        <table class="racecard_table">
          <tr class="n1">
            <td class="num"><span>1</span></td>
            <td class="rider bdr_r">A</td>
            <td class="bdr_r">逃</td>
            <span class="icon_t1">◎</span>
          </tr>
          <tr class="n2">
            <td class="num"><span>2</span></td>
            <td class="rider bdr_r">B</td>
            <td class="bdr_r">両</td>
            <span class="icon_t2">○</span>
          </tr>
          <tr class="n3">
            <td class="num"><span>3</span></td>
            <td class="rider bdr_r">C</td>
            <td class="bdr_r">追</td>
            <span class="icon_t3">▲</span>
          </tr>
          脚<br>質
        </table>
        <div class="odds_contents" id="JS_ODDSCONTENTS_2shatan">
          <table class="odds_table">
            <tr><th class="n1">1</th><td>1.2</td><td>2.3</td></tr>
            <tr><th class="n2">2</th><td>2.1</td><td>3.4</td></tr>
            <tr><th class="n3">3</th><td>3.1</td><td>4.4</td></tr>
          </table>
          <!-- 2車単 End -->
        </div>
      HTML
      cache_path = File.join(cache_dir, "race_#{Digest::SHA1.hexdigest(url)}.html")
      File.write(cache_path, html)

      write_csv(
        File.join(raw_dir, "girls_results_20260226.csv"),
        %w[race_date venue race_number racedetail_id show_result_url rank result_status frame_number car_number player_name age class raw_cells],
        [
          { "race_date" => "2026-02-26", "venue" => "toride", "race_number" => "1", "racedetail_id" => "x", "show_result_url" => "u", "rank" => "1", "result_status" => "normal", "frame_number" => "", "car_number" => "1", "player_name" => "A", "age" => "", "class" => "", "raw_cells" => "" },
          { "race_date" => "2026-02-26", "venue" => "toride", "race_number" => "1", "racedetail_id" => "x", "show_result_url" => "u", "rank" => "2", "result_status" => "normal", "frame_number" => "", "car_number" => "2", "player_name" => "B", "age" => "", "class" => "", "raw_cells" => "" },
          { "race_date" => "2026-02-26", "venue" => "toride", "race_number" => "1", "racedetail_id" => "x", "show_result_url" => "u", "rank" => "3", "result_status" => "normal", "frame_number" => "", "car_number" => "3", "player_name" => "C", "age" => "", "class" => "", "raw_cells" => "" }
        ]
      )

      encoders = {
        "venue" => { "toride" => 0 },
        "player_name" => { "A" => 0, "B" => 1, "C" => 2 },
        "mark_symbol" => { "◎" => 0, "○" => 1, "▲" => 2 },
        "leg_style" => { "逃" => 0, "両" => 1, "追" => 2 }
      }
      File.write(File.join(model_dir, "model_top3.txt"), "dummy")
      File.write(File.join(model_dir, "model_top1.txt"), "dummy")
      File.write(File.join(model_dir, "enc_top3.json"), JSON.pretty_generate(encoders))
      File.write(File.join(model_dir, "enc_top1.json"), JSON.pretty_generate(encoders))

      out, err, st = run_cmd(
        "ruby", "scripts/predict_race.rb",
        "--url", url,
        "--model-top3", File.join(model_dir, "model_top3.txt"),
        "--encoders-top3", File.join(model_dir, "enc_top3.json"),
        "--model-top1", File.join(model_dir, "model_top1.txt"),
        "--encoders-top1", File.join(model_dir, "enc_top1.json"),
        "--raw-dir", raw_dir,
        "--cache-dir", cache_dir,
        "--exacta-top", "3",
        "--trifecta-top", "3",
        "--no-bet-gap-threshold", "0.05",
        "--cache",
        env: env
      )
      expect(st.success?).to be(true), err
      expect(out).to include("# レース: toride")
      expect(out).to include("## 2連単 Top 3")
      expect(out).to include("## 3連単 Top 3")
    end
  end

  it "exactaモデル指定時は2連単にexacta専用モデルを使う" do
    Dir.mktmpdir("spec-predict-exacta-") do |tmp|
      bin_dir = File.join(tmp, "bin")
      create_fake_lightgbm(bin_dir)
      env = { "PATH" => "#{bin_dir}:#{ENV.fetch('PATH', '')}" }

      url = "https://keirin.kdreams.jp/toride/racedetail/2320260225030004/"
      cache_dir = File.join(tmp, "cache")
      raw_dir = File.join(tmp, "raw")
      model_dir = File.join(tmp, "models")
      FileUtils.mkdir_p(cache_dir)
      FileUtils.mkdir_p(raw_dir)
      FileUtils.mkdir_p(model_dir)

      html = <<~HTML
        <table class="racecard_table">
          <tr class="n1"><td class="num"><span>1</span></td><td class="rider bdr_r">A</td><td class="bdr_r">逃</td><span class="icon_t1">◎</span></tr>
          <tr class="n2"><td class="num"><span>2</span></td><td class="rider bdr_r">B</td><td class="bdr_r">両</td><span class="icon_t2">○</span></tr>
          <tr class="n3"><td class="num"><span>3</span></td><td class="rider bdr_r">C</td><td class="bdr_r">追</td><span class="icon_t3">▲</span></tr>
          脚<br>質
        </table>
        <div class="odds_contents" id="JS_ODDSCONTENTS_2shatan">
          <table class="odds_table">
            <tr><th class="n1">1</th><td>1.2</td><td>2.3</td></tr>
            <tr><th class="n2">2</th><td>2.1</td><td>3.4</td></tr>
            <tr><th class="n3">3</th><td>3.1</td><td>4.4</td></tr>
          </table>
          <!-- 2車単 End -->
        </div>
      HTML
      cache_path = File.join(cache_dir, "race_#{Digest::SHA1.hexdigest(url)}.html")
      File.write(cache_path, html)

      write_csv(
        File.join(raw_dir, "girls_results_20260226.csv"),
        %w[race_date venue race_number racedetail_id show_result_url rank result_status frame_number car_number player_name age class raw_cells],
        [
          { "race_date" => "2026-02-26", "venue" => "toride", "race_number" => "1", "racedetail_id" => "x", "show_result_url" => "u", "rank" => "1", "result_status" => "normal", "frame_number" => "", "car_number" => "1", "player_name" => "A", "age" => "", "class" => "", "raw_cells" => "" },
          { "race_date" => "2026-02-26", "venue" => "toride", "race_number" => "1", "racedetail_id" => "x", "show_result_url" => "u", "rank" => "2", "result_status" => "normal", "frame_number" => "", "car_number" => "2", "player_name" => "B", "age" => "", "class" => "", "raw_cells" => "" },
          { "race_date" => "2026-02-26", "venue" => "toride", "race_number" => "1", "racedetail_id" => "x", "show_result_url" => "u", "rank" => "3", "result_status" => "normal", "frame_number" => "", "car_number" => "3", "player_name" => "C", "age" => "", "class" => "", "raw_cells" => "" }
        ]
      )

      encoders = {
        "venue" => { "toride" => 0 },
        "player_name" => { "A" => 0, "B" => 1, "C" => 2 },
        "mark_symbol" => { "◎" => 0, "○" => 1, "▲" => 2 },
        "leg_style" => { "逃" => 0, "両" => 1, "追" => 2 }
      }
      File.write(File.join(model_dir, "model_top3.txt"), "dummy")
      File.write(File.join(model_dir, "model_top1.txt"), "dummy")
      File.write(File.join(model_dir, "enc_top3.json"), JSON.pretty_generate(encoders))
      File.write(File.join(model_dir, "enc_top1.json"), JSON.pretty_generate(encoders))
      File.write(File.join(model_dir, "model_exacta.txt"), "dummy")
      File.write(File.join(model_dir, "enc_exacta.json"), "{}")

      out, err, st = run_cmd(
        "ruby", "scripts/predict_race.rb",
        "--url", url,
        "--model-top3", File.join(model_dir, "model_top3.txt"),
        "--encoders-top3", File.join(model_dir, "enc_top3.json"),
        "--model-top1", File.join(model_dir, "model_top1.txt"),
        "--encoders-top1", File.join(model_dir, "enc_top1.json"),
        "--model-exacta", File.join(model_dir, "model_exacta.txt"),
        "--encoders-exacta", File.join(model_dir, "enc_exacta.json"),
        "--exacta-model",
        "--raw-dir", raw_dir,
        "--cache-dir", cache_dir,
        "--exacta-top", "3",
        "--trifecta-top", "3",
        "--cache",
        env: env
      )
      expect(st.success?).to be(true), err
      expect(out).to include("2連単スコア源: exacta専用モデル")
      expect(out).to include("## 2連単 Top 3 [standard/exacta_model]")
    end
  end

  it "exactaモデルが存在しても未指定なら従来スコアを使う" do
    Dir.mktmpdir("spec-predict-exacta-default-off-") do |tmp|
      bin_dir = File.join(tmp, "bin")
      create_fake_lightgbm(bin_dir)
      env = { "PATH" => "#{bin_dir}:#{ENV.fetch('PATH', '')}" }

      url = "https://keirin.kdreams.jp/toride/racedetail/2320260225030004/"
      cache_dir = File.join(tmp, "cache")
      raw_dir = File.join(tmp, "raw")
      model_dir = File.join(tmp, "models")
      FileUtils.mkdir_p(cache_dir)
      FileUtils.mkdir_p(raw_dir)
      FileUtils.mkdir_p(model_dir)

      html = <<~HTML
        <table class="racecard_table">
          <tr class="n1"><td class="num"><span>1</span></td><td class="rider bdr_r">A</td><td class="bdr_r">逃</td><span class="icon_t1">◎</span></tr>
          <tr class="n2"><td class="num"><span>2</span></td><td class="rider bdr_r">B</td><td class="bdr_r">両</td><span class="icon_t2">○</span></tr>
          <tr class="n3"><td class="num"><span>3</span></td><td class="rider bdr_r">C</td><td class="bdr_r">追</td><span class="icon_t3">▲</span></tr>
          脚<br>質
        </table>
        <div class="odds_contents" id="JS_ODDSCONTENTS_2shatan">
          <table class="odds_table">
            <tr><th class="n1">1</th><td>1.2</td><td>2.3</td></tr>
            <tr><th class="n2">2</th><td>2.1</td><td>3.4</td></tr>
            <tr><th class="n3">3</th><td>3.1</td><td>4.4</td></tr>
          </table>
          <!-- 2車単 End -->
        </div>
      HTML
      cache_path = File.join(cache_dir, "race_#{Digest::SHA1.hexdigest(url)}.html")
      File.write(cache_path, html)

      write_csv(
        File.join(raw_dir, "girls_results_20260226.csv"),
        %w[race_date venue race_number racedetail_id show_result_url rank result_status frame_number car_number player_name age class raw_cells],
        [
          { "race_date" => "2026-02-26", "venue" => "toride", "race_number" => "1", "racedetail_id" => "x", "show_result_url" => "u", "rank" => "1", "result_status" => "normal", "frame_number" => "", "car_number" => "1", "player_name" => "A", "age" => "", "class" => "", "raw_cells" => "" },
          { "race_date" => "2026-02-26", "venue" => "toride", "race_number" => "1", "racedetail_id" => "x", "show_result_url" => "u", "rank" => "2", "result_status" => "normal", "frame_number" => "", "car_number" => "2", "player_name" => "B", "age" => "", "class" => "", "raw_cells" => "" },
          { "race_date" => "2026-02-26", "venue" => "toride", "race_number" => "1", "racedetail_id" => "x", "show_result_url" => "u", "rank" => "3", "result_status" => "normal", "frame_number" => "", "car_number" => "3", "player_name" => "C", "age" => "", "class" => "", "raw_cells" => "" }
        ]
      )

      encoders = {
        "venue" => { "toride" => 0 },
        "player_name" => { "A" => 0, "B" => 1, "C" => 2 },
        "mark_symbol" => { "◎" => 0, "○" => 1, "▲" => 2 },
        "leg_style" => { "逃" => 0, "両" => 1, "追" => 2 }
      }
      File.write(File.join(model_dir, "model_top3.txt"), "dummy")
      File.write(File.join(model_dir, "model_top1.txt"), "dummy")
      File.write(File.join(model_dir, "enc_top3.json"), JSON.pretty_generate(encoders))
      File.write(File.join(model_dir, "enc_top1.json"), JSON.pretty_generate(encoders))
      File.write(File.join(model_dir, "model_exacta.txt"), "dummy")
      File.write(File.join(model_dir, "enc_exacta.json"), "{}")

      out, err, st = run_cmd(
        "ruby", "scripts/predict_race.rb",
        "--url", url,
        "--model-top3", File.join(model_dir, "model_top3.txt"),
        "--encoders-top3", File.join(model_dir, "enc_top3.json"),
        "--model-top1", File.join(model_dir, "model_top1.txt"),
        "--encoders-top1", File.join(model_dir, "enc_top1.json"),
        "--model-exacta", File.join(model_dir, "model_exacta.txt"),
        "--encoders-exacta", File.join(model_dir, "enc_exacta.json"),
        "--raw-dir", raw_dir,
        "--cache-dir", cache_dir,
        "--exacta-top", "3",
        "--trifecta-top", "3",
        "--cache",
        env: env
      )
      expect(st.success?).to be(true), err
      expect(out).to include("2連単スコア源: top1/top3合成(従来)")
      expect(out).to include("## 2連単 Top 3 [standard/heuristic]")
    end
  end

  it "bet-style不正値はエラーになる" do
    _out, err, st = run_cmd(
      "ruby", "scripts/predict_race.rb",
      "--url", "https://keirin.kdreams.jp/toride/racedetail/2320260225030004/",
      "--bet-style", "bad"
    )
    expect(st.success?).to be(false)
    expect(err).to include("--bet-style must be one of: standard, solid, value")
  end

  it "unitが0以下ならエラーになる" do
    _out, err, st = run_cmd(
      "ruby", "scripts/predict_race.rb",
      "--url", "https://keirin.kdreams.jp/toride/racedetail/2320260225030004/",
      "--unit", "0"
    )
    expect(st.success?).to be(false)
    expect(err).to include("--unit must be > 0")
  end

  it "kelly-capが範囲外ならエラーになる" do
    _out, err, st = run_cmd(
      "ruby", "scripts/predict_race.rb",
      "--url", "https://keirin.kdreams.jp/toride/racedetail/2320260225030004/",
      "--kelly-cap", "-0.1"
    )
    expect(st.success?).to be(false)
    expect(err).to include("--kelly-cap must be between 0 and 1")
  end

  it "url未指定はusageで終了する" do
    _out, err, st = run_cmd("ruby", "scripts/predict_race.rb")
    expect(st.success?).to be(false)
    expect(err).to include("Usage: ruby scripts/predict_race.rb")
  end

  it "model manifestの特徴量不一致ならエラーになる" do
    Dir.mktmpdir("spec-predict-manifest-mismatch-") do |tmp|
      bin_dir = File.join(tmp, "bin")
      create_fake_lightgbm(bin_dir)
      env = { "PATH" => "#{bin_dir}:#{ENV.fetch('PATH', '')}" }

      url = "https://keirin.kdreams.jp/toride/racedetail/2320260225030004/"
      cache_dir = File.join(tmp, "cache")
      raw_dir = File.join(tmp, "raw")
      model_dir = File.join(tmp, "models")
      FileUtils.mkdir_p(cache_dir)
      FileUtils.mkdir_p(raw_dir)
      FileUtils.mkdir_p(model_dir)
      File.write(File.join(cache_dir, "race_#{Digest::SHA1.hexdigest(url)}.html"), "<table class=\"racecard_table\">脚<br>質</table>")
      write_csv(
        File.join(raw_dir, "girls_results_20260226.csv"),
        %w[race_date venue race_number racedetail_id show_result_url rank result_status frame_number car_number player_name age class raw_cells],
        []
      )
      File.write(File.join(model_dir, "model_top3.txt"), "dummy")
      File.write(File.join(model_dir, "model_top1.txt"), "dummy")
      File.write(File.join(model_dir, "enc_top3.json"), "{}")
      File.write(File.join(model_dir, "enc_top1.json"), "{}")
      File.write(
        File.join(model_dir, "model_manifest.json"),
        JSON.pretty_generate({ "feature_columns_digest" => "deadbeef" })
      )

      _out, err, st = run_cmd(
        "ruby", "scripts/predict_race.rb",
        "--url", url,
        "--model-top3", File.join(model_dir, "model_top3.txt"),
        "--encoders-top3", File.join(model_dir, "enc_top3.json"),
        "--model-top1", File.join(model_dir, "model_top1.txt"),
        "--encoders-top1", File.join(model_dir, "enc_top1.json"),
        "--raw-dir", raw_dir,
        "--cache-dir", cache_dir,
        "--cache",
        env: env
      )
      expect(st.success?).to be(false)
      expect(err).to match(/model manifest (mismatch|missing keys)/)
    end
  end
end
