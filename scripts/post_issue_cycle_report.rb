#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require "optparse"
require "time"

def run!(*cmd)
  out, err, st = Open3.capture3(*cmd)
  raise "command failed: #{cmd.join(' ')}\n#{err}\n#{out}" unless st.success?

  out.force_encoding("UTF-8").encode("UTF-8", invalid: :replace, undef: :replace)
end

options = {
  parent_issue: 32,
  since_hours: 24,
  commits: 10,
  issues: 20,
  dry_run: false
}

OptionParser.new do |opts|
  opts.banner = "Usage: ruby scripts/post_issue_cycle_report.rb [options]"
  opts.on("--parent-issue N", Integer, "投稿先の親Issue番号 (default: 32)") { |v| options[:parent_issue] = v }
  opts.on("--since-hours N", Integer, "集計期間 (default: 24)") { |v| options[:since_hours] = v }
  opts.on("--commits N", Integer, "掲載するコミット数 (default: 10)") { |v| options[:commits] = v }
  opts.on("--issues N", Integer, "参照するclosed issue数 (default: 20)") { |v| options[:issues] = v }
  opts.on("--dry-run", "コメント投稿せず本文だけ表示") { options[:dry_run] = true }
end.parse!

since_time = Time.now - (options[:since_hours] * 3600)
since_iso = since_time.utc.iso8601

closed_json = run!(
  "gh", "issue", "list",
  "--state", "closed",
  "--limit", options[:issues].to_s,
  "--json", "number,title,closedAt"
)
closed_issues = JSON.parse(closed_json)
  .select { |i| i["closedAt"] && Time.parse(i["closedAt"]) >= since_time }
  .sort_by { |i| i["closedAt"] }
  .reverse

git_since = since_time.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
log_text = run!(
  "git", "log",
  "--since", git_since,
  "--max-count", options[:commits].to_s,
  "--pretty=format:%h %s"
)
commits = log_text.lines.map(&:strip).reject(&:empty?)

body_lines = []
body_lines << "Issue cycle 自動レポート（直近 #{options[:since_hours]}h）"
body_lines << ""
body_lines << "- 集計時刻: #{Time.now.utc.iso8601}"
body_lines << "- 対象期間開始: #{since_iso}"
body_lines << ""
body_lines << "完了Issue:"
if closed_issues.empty?
  body_lines << "- なし"
else
  closed_issues.each { |i| body_lines << "- ##{i['number']} #{i['title']}" }
end
body_lines << ""
body_lines << "関連コミット:"
if commits.empty?
  body_lines << "- なし"
else
  commits.each { |c| body_lines << "- #{c}" }
end

body = body_lines.join("\n")

if options[:dry_run]
  puts body
  exit 0
end

run!("gh", "issue", "comment", options[:parent_issue].to_s, "--body", body)
warn "posted_parent_issue=#{options[:parent_issue]}"
