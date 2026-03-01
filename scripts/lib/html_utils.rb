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

    # Returns ordered entry rows from race detail HTML.
    # Example element:
    # { car_number: 1, player_name: "選手A", mark_symbol: "◎", leg_style: "逃" }
    def parse_racecard_entries(html)
      table = extract_racecard_table(html)
      return [] if table.nil?

      table.scan(/<tr class="n\d+[^"]*">(.*?)<\/tr>/m).flatten.map do |tr|
        car_number = tr.match(/<td class="num"><span>(\d+)<\/span><\/td>/m)&.[](1).to_i
        next if car_number.zero?

        player_html = tr.match(/<td class="rider bdr_r">(.*?)<\/td>/m)&.[](1).to_s
        {
          car_number: car_number,
          player_name: normalize_text(player_html.split("<br>").first),
          mark_symbol: tr.match(/icon_t\d+">([^<]+)</m)&.[](1).to_s.strip,
          leg_style: tr.match(/<td class="bdr_r">\s*(逃|両|追)\s*<\/td>/m)&.[](1).to_s.strip
        }
      end.compact.sort_by { |e| e[:car_number] }
    end

    # Parses race detail page into a JSON-friendly hash.
    # This is useful for sharing one parse result between scripts.
    def parse_race_detail_json(html)
      odds_2shatan = parse_2shatan_odds_data(html)
      odds_3rentan = parse_3rentan_odds(html)

      {
        "entries" => parse_racecard_entries(html).map do |e|
          {
            "car_number" => e[:car_number],
            "player_name" => e[:player_name],
            "mark_symbol" => e[:mark_symbol],
            "leg_style" => e[:leg_style]
          }
        end,
        "odds" => {
          "exacta_min_by_first" => odds_2shatan[:min_by_first].sort.to_h.transform_keys(&:to_s),
          "exacta_pairs" => odds_map_to_json_hash(odds_2shatan[:pair_odds]),
          "trifecta_pairs" => odds_map_to_json_hash(odds_3rentan),
          "popular_exacta" => parse_2shatan_popular_odds(html).map do |a, b, odd|
            { "first_car_number" => a, "second_car_number" => b, "odds" => odd }
          end,
          "popular_trifecta" => parse_3rentan_popular_odds(html).map do |a, b, c, odd|
            { "first_car_number" => a, "second_car_number" => b, "third_car_number" => c, "odds" => odd }
          end
        }
      }
    end

    # Parses race detail page for data discovery.
    # Includes broad table/link extraction in addition to known fields.
    def parse_race_detail_full_json(html)
      parse_race_detail_json(html).merge(
        "result_rows" => parse_result_table_rows(html),
        "tables" => parse_all_tables(html),
        "links" => parse_all_links(html)
      )
    end

    def parse_2shatan_odds(html)
      parse_2shatan_odds_data(html)[:min_by_first]
    end

    def parse_2shatan_pair_odds(html)
      parse_2shatan_odds_data(html)[:pair_odds]
    end

    def parse_2shatan_odds_data(html)
      section = html.match(/<div class="odds_contents[^"]*" id="JS_ODDSCONTENTS_2shatan">(.*?)<!-- 2車単 End -->/m)&.[](1)
      return { min_by_first: {}, pair_odds: {} } if section.nil?

      table = section.match(/<table class="odds_table">(.*?)<\/table>/m)&.[](1)
      return { min_by_first: {}, pair_odds: {} } if table.nil?

      min_by_first = {}
      pair_odds = {}
      col_cars = table.scan(/<tr>\s*<th rowspan="2">.*?<\/th>(.*?)<th rowspan="2">/m).flatten.first.to_s
                      .scan(/<th class="n(\d+)">/).flatten.map(&:to_i)
      return { min_by_first: {}, pair_odds: {} } if col_cars.empty?

      table.scan(/<tr>\s*<th class="n(\d+)">.*?<\/th>(.*?)<th class="n\1">/m).each do |row_second, row_body|
        second_car = row_second.to_i
        cells = row_body.scan(/<td[^>]*>(.*?)<\/td>/m).flatten
        col_cars.each_with_index do |first_car, idx|
          next if idx >= cells.size
          odd = parse_odds_value(cells[idx])
          next if odd.nil? || first_car == second_car

          pair_odds[[first_car, second_car]] = odd
          current_min = min_by_first[first_car]
          min_by_first[first_car] = current_min.nil? ? odd : [current_min, odd].min
        end
      end
      { min_by_first: min_by_first, pair_odds: pair_odds }
    end

    def parse_3rentan_odds(html)
      section = html.match(/<div class="odds_contents[^"]*" id="JS_ODDSCONTENTS_3rentan">(.*?)<!-- 3連単 End -->/m)&.[](1)
      return {} if section.nil?

      odds = {}
      section.scan(/<table class="odds_table bt5[^"]*">(.*?)<\/table>/m).flatten.each do |table_html|
        first_car = table_html.match(/<th class="n(\d+)"/)&.[](1).to_i
        next if first_car.zero?

        second_cars = table_html.scan(/<tr>\s*<th rowspan="2">.*?<\/th>(.*?)<th rowspan="2">/m).flatten.first
        next if second_cars.nil?

        col_cars = second_cars.scan(/<th class="n(\d+)">/).flatten.map(&:to_i)
        next if col_cars.empty?

        table_html.scan(/<tr>\s*<th class="n(\d+)">.*?<\/th>(.*?)<th class="n\1">/m).each do |row_third, row_body|
          third_car = row_third.to_i
          cells = row_body.scan(/<td[^>]*>(.*?)<\/td>/m).flatten
          col_cars.each_with_index do |second_car, idx|
            next if idx >= cells.size
            odd = parse_odds_value(cells[idx])
            next if odd.nil?
            next unless first_car != second_car && second_car != third_car && first_car != third_car

            odds[[first_car, second_car, third_car]] = odd
          end
        end
      end
      odds
    end

    def parse_2shatan_popular_odds(html)
      section = html.match(/<div class="odds_contents[^"]*" id="JS_ODDSCONTENTS_2shatan">(.*?)<!-- 2車単 End -->/m)&.[](1)
      return [] if section.nil?

      section.scan(/<span class="num">(\d+)-(\d+)<\/span><span class="odds">([^<]+)<\/span>/m).map do |a, b, odd|
        [a.to_i, b.to_i, odd.to_f]
      end
    end

    def parse_3rentan_popular_odds(html)
      section = html.match(/<div class="odds_contents[^"]*" id="JS_ODDSCONTENTS_3rentan">(.*?)<!-- 3連単 End -->/m)&.[](1)
      return [] if section.nil?

      section.scan(/<span class="num">(\d+)-(\d+)-(\d+)<\/span><span class="odds">([^<]+)<\/span>/m).map do |a, b, c, odd|
        [a.to_i, b.to_i, c.to_i, odd.to_f]
      end
    end

    def extract_racecard_table(html)
      html.scan(/<table class="racecard_table[^"]*">(.*?)<\/table>/m)
          .map(&:first)
          .find { |t| t.include?("脚<br>質") && t.include?('class="num"') }
    end

    def odds_map_to_json_hash(odds_map)
      odds_map.each_with_object({}) do |(cars, odd), out|
        out[Array(cars).join("-")] = odd
      end.sort.to_h
    end

    def parse_result_table_rows(html)
      table = html.match(/<table class="result_table">(.*?)<\/table>/im)&.[](1)
      return [] if table.nil?

      table.scan(/<tr[^>]*>(.*?)<\/tr>/im).flatten.map do |tr|
        tr.scan(/<t[dh][^>]*>(.*?)<\/t[dh]>/im).flatten.map { |c| normalize_text(c) }
      end.reject(&:empty?)
    end

    def parse_all_tables(html)
      html.scan(/<table([^>]*)>(.*?)<\/table>/im).each_with_index.map do |(attrs, body), idx|
        rows = body.scan(/<tr[^>]*>(.*?)<\/tr>/im).flatten.map do |tr|
          tr.scan(/<t[dh][^>]*>(.*?)<\/t[dh]>/im).flatten.map { |c| normalize_text(c) }
        end.reject(&:empty?)

        {
          "index" => idx + 1,
          "class" => attrs.to_s[/class="([^"]*)"/i, 1].to_s,
          "id" => attrs.to_s[/id="([^"]*)"/i, 1].to_s,
          "row_count" => rows.size,
          "column_count_max" => rows.map(&:size).max || 0,
          "rows" => rows
        }
      end
    end

    def parse_all_links(html)
      html.scan(/<a[^>]*href="([^"]+)"[^>]*>(.*?)<\/a>/im).map do |href, body|
        {
          "href" => href,
          "text" => normalize_text(body)
        }
      end.uniq { |x| [x["href"], x["text"]] }
    end
  end
end
