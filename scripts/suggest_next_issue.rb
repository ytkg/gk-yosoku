#!/usr/bin/env ruby
# frozen_string_literal: true

require "open3"
require "optparse"

def run!(*cmd)
  out, err, st = Open3.capture3(*cmd)
  raise "command failed: #{cmd.join(' ')}\n#{err}\n#{out}" unless st.success?

  out.force_encoding("UTF-8").encode("UTF-8", invalid: :replace, undef: :replace)
end

def extract_first_candidate(project_plan_path)
  text = File.read(project_plan_path, encoding: "UTF-8")
  section = text[/## 次の改善候補\n\n(.+?)(?:\n## |\z)/m, 1]
  return nil if section.nil?

  line = section.lines.map(&:strip).find { |l| l.match?(/\A1\.\s+/) }
  return nil if line.nil?

  line.sub(/\A1\.\s*/, "")
end

options = {
  parent_issue: 32,
  project_plan_path: File.join("docs", "project-plan.md")
}

OptionParser.new do |opts|
  opts.banner = "Usage: ruby scripts/suggest_next_issue.rb [options]"
  opts.on("--parent-issue N", Integer, "親Issue番号 (default: 32)") { |v| options[:parent_issue] = v }
  opts.on("--project-plan-path PATH", "候補抽出元 (default: docs/project-plan.md)") { |v| options[:project_plan_path] = v }
end.parse!

open_lines = run!("gh", "issue", "list", "--state", "open", "--limit", "200").lines
children = open_lines.reject { |line| line.start_with?("#{options[:parent_issue]}\t") }

if children.any?
  warn "open child issues exist (count=#{children.size})"
  warn "suggestion is skipped until only parent issue remains"
  exit 0
end

candidate = extract_first_candidate(options[:project_plan_path])
if candidate.nil? || candidate.empty?
  warn "no candidate found in #{options[:project_plan_path]}"
  exit 1
end

warn "next_issue_suggestion=#{candidate}"
