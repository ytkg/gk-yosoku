# frozen_string_literal: true

require "spec_helper"

RSpec.describe "compare_time_decay_half_life" do
  it "half-life候補を実行してleaderboardを生成できる" do
    Dir.mktmpdir("spec-half-life-grid-") do |tmp|
      fake_cv = File.join(tmp, "fake_cv.rb")
      File.write(
        fake_cv,
        <<~RUBY
          #!/usr/bin/env ruby
          require "fileutils"
          require "json"

          args = ARGV.each_slice(2).to_h
          out_dir = args.fetch("--out-dir")
          half_life = args.fetch("--decay-half-life-days").to_f
          FileUtils.mkdir_p(out_dir)
          summary = {
            "folds" => 2,
            "target_col" => args.fetch("--target-col"),
            "metrics" => {
              "auc" => { "mean" => (0.60 + half_life / 1000.0) },
              "winner_hit_rate" => { "mean" => (0.10 + half_life / 1000.0) },
              "top3_exact_match_rate" => { "mean" => (0.30 - half_life / 1000.0) },
              "top3_recall_at3" => { "mean" => 0.4 }
            }
          }
          File.write(File.join(out_dir, "cv_summary.json"), JSON.pretty_generate(summary))
        RUBY
      )
      FileUtils.chmod("u+x", fake_cv)

      out_dir = File.join(tmp, "out")
      _out, err, st = run_cmd(
        "ruby", "scripts/compare_time_decay_half_life.rb",
        "--from-date", "2026-01-01",
        "--to-date", "2026-02-01",
        "--half-lives", "60,120",
        "--out-dir", out_dir,
        "--cv-script", fake_cv
      )
      expect(st.success?).to be(true), err

      leaderboard = CSV.read(File.join(out_dir, "half_life_leaderboard.csv"), headers: true)
      summary = JSON.parse(File.read(File.join(out_dir, "half_life_summary.json"), encoding: "UTF-8"))
      expect(leaderboard.size).to eq(2)
      expect(leaderboard[0]["half_life_days"]).to eq("120.0")
      expect(summary.dig("best", "half_life_days")).to eq(120.0)
      expect(summary["recommended_half_life_days"]).to eq(120.0)
      expect(summary["candidates"]).to eq(2)
      expect(summary.dig("options", "sort_metric")).to eq("winner_hit_rate_mean")
      expect(summary.dig("options", "half_lives")).to eq([60.0, 120.0])
      expect(err).to include("recommended_half_life_days=120.0")

      out_dir2 = File.join(tmp, "out_top3")
      _out2, err2, st2 = run_cmd(
        "ruby", "scripts/compare_time_decay_half_life.rb",
        "--from-date", "2026-01-01",
        "--to-date", "2026-02-01",
        "--half-lives", "60,120",
        "--sort-metric", "top3_exact_match_rate_mean",
        "--out-dir", out_dir2,
        "--cv-script", fake_cv
      )
      expect(st2.success?).to be(true), err2
      summary2 = JSON.parse(File.read(File.join(out_dir2, "half_life_summary.json"), encoding: "UTF-8"))
      expect(summary2["recommended_half_life_days"]).to eq(60.0)
      expect(summary2.dig("options", "sort_metric")).to eq("top3_exact_match_rate_mean")
    end
  end
end
