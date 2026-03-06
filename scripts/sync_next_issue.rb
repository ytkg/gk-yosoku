#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require "optparse"
require "tempfile"

def run!(*cmd)
  out, err, st = Open3.capture3(*cmd)
  raise "command failed: #{cmd.join(' ')}\n#{err}\n#{out}" unless st.success?

  out
end

def priority_rank(labels)
  priority = labels.map { |label| label["name"] }.find { |name| name.start_with?("priority: ") }
  return 9 unless priority

  case priority
  when "priority: P1" then 1
  when "priority: P2" then 2
  when "priority: P3" then 3
  else 9
  end
end

def replace_next_section(body, next_line)
  section = "## 次候補\n#{next_line}\n"
  if body.match?(/^## 次候補$/)
    body.sub(/^## 次候補\n(?:- .*\n)*/m, section)
  else
    "#{body.rstrip}\n\n#{section}"
  end
end

options = {
  parent_issue: 32,
  limit: 200,
  dry_run: false
}

OptionParser.new do |opts|
  opts.banner = "Usage: ruby scripts/sync_next_issue.rb [options]"
  opts.on("--parent-issue N", Integer, "親Issue番号 (default: 32)") { |v| options[:parent_issue] = v }
  opts.on("--limit N", Integer, "open issue取得件数 (default: 200)") { |v| options[:limit] = v }
  opts.on("--dry-run", "更新せずに差分候補を表示") { options[:dry_run] = true }
end.parse!

issues_json = run!("gh", "issue", "list", "--state", "open", "--limit", options[:limit].to_s, "--json", "number,title,labels")
issues = JSON.parse(issues_json)
children = issues.reject { |issue| issue["number"] == options[:parent_issue] }
next_issue = children.min_by { |issue| [priority_rank(issue.fetch("labels", [])), issue["number"]] }

next_line =
  if next_issue
    "- ##{next_issue['number']} #{next_issue['title']}"
  else
    "- （子Issueなし）"
  end

parent_body = run!("gh", "issue", "view", options[:parent_issue].to_s, "--json", "body", "-q", ".body")
updated_body = replace_next_section(parent_body, next_line)

if options[:dry_run]
  warn "next_candidate=#{next_line}"
  exit 0
end

Tempfile.create("issue_body") do |f|
  f.write(updated_body)
  f.flush
  run!("gh", "issue", "edit", options[:parent_issue].to_s, "--body-file", f.path)
end

warn "updated_parent_issue=#{options[:parent_issue]}"
warn "next_candidate=#{next_line}"
