# frozen_string_literal: true

require "spec_helper"
require_relative "../../scripts/predict_race"

RSpec.describe "predict_race api exit codes" do
  it "APIエラーコードに対応する終了コードを返す" do
    expect(api_error_exit_code("invalid_request")).to eq(2)
    expect(api_error_exit_code("predict_failed")).to eq(3)
    expect(api_error_exit_code("predict_timeout")).to eq(4)
    expect(api_error_exit_code("internal_error")).to eq(5)
    expect(api_error_exit_code("unknown_code")).to eq(1)
  end
end
