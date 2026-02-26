# frozen_string_literal: true

require "nkf"

module GK
  module HtmlUtils
    module_function

    def normalize_body(body, content_type)
      raw = body.dup
      charset = content_type.to_s[/charset=([^\s;]+)/i, 1]
      enc = begin
        charset ? Encoding.find(charset) : NKF.guess(raw)
      rescue StandardError
        Encoding::UTF_8
      end
      raw.force_encoding(enc)
      raw.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
    end

    def normalize_text(text)
      text.to_s
          .gsub(/<[^>]+>/, " ")
          .gsub(/&nbsp;/i, " ")
          .gsub(/&amp;/i, "&")
          .gsub(/\s+/, " ")
          .strip
    end

    def parse_odds_value(cell_html)
      text = normalize_text(cell_html)
      return nil if text.empty? || text == "-"

      m = text.match(/(\d+(?:\.\d+)?)/)
      return nil if m.nil?

      m[1].to_f
    end

    def parse_2shatan_odds(html)
      section = html.match(/<div class="odds_contents[^"]*" id="JS_ODDSCONTENTS_2shatan">(.*?)<!-- 2車単 End -->/m)&.[](1)
      return {} if section.nil?

      table = section.match(/<table class="odds_table">(.*?)<\/table>/m)&.[](1)
      return {} if table.nil?

      min_by_first = {}
      table.scan(/<tr>(.*?)<\/tr>/m).flatten.each do |tr|
        first_car = tr.match(/<th class="n\d+">(\d+)<\/th>/)&.[](1).to_i
        next if first_car.zero?

        cells = tr.scan(/<td[^>]*>(.*?)<\/td>/m).flatten
        odds_values = cells.map { |cell| parse_odds_value(cell) }.compact
        next if odds_values.empty?

        min_by_first[first_car] = odds_values.min
      end
      min_by_first
    end
  end
end
