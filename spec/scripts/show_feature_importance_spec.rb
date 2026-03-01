# frozen_string_literal: true

require "spec_helper"

RSpec.describe "show_feature_importance.rb" do
  it "feature_importancesセクションを表示できる" do
    Dir.mktmpdir("spec-importance-") do |tmp|
      model_path = File.join(tmp, "model.txt")
      File.write(model_path, <<~MODEL)
        tree
        feature_importances:
        Column_0=10
        Column_1=5

      MODEL
      File.write(File.join(tmp, "feature_columns.json"), JSON.pretty_generate(["feat_a", "feat_b", "feat_c"]))

      out, err, st = run_cmd(
        "ruby", "scripts/show_feature_importance.rb",
        "--model", model_path,
        "--top", "2"
      )
      expect(st.success?).to be(true), err
      expect(out).to include("model=#{model_path}")
      expect(out).to include("10 feat_a")
      expect(out).to include(" 5 feat_b")
      expect(out).not_to include("feat_c")
    end
  end

  it "feature_importancesセクションがなくても0として表示できる" do
    Dir.mktmpdir("spec-importance-no-section-") do |tmp|
      model_path = File.join(tmp, "model.txt")
      File.write(model_path, "just a model body\n")
      File.write(File.join(tmp, "feature_columns.json"), JSON.pretty_generate(["feat_x", "feat_y"]))

      out, err, st = run_cmd(
        "ruby", "scripts/show_feature_importance.rb",
        "--model", model_path,
        "--top", "2"
      )
      expect(st.success?).to be(true), err
      expect(out).to include("model=#{model_path}")
      expect(out).to include("0 feat_x")
      expect(out).to include("0 feat_y")
    end
  end
end
