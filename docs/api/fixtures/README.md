# parity fixtures

- `parity_request.json`: CLI/API同値性検証で使う入力payload
- `raw/`: 履歴CSVの固定fixture
- `cache/`: 予測対象レースHTMLの固定fixture

更新方針:
1. `parity_request.json` の `url` を変更したら、対応する `cache/race_<sha1(url)>.html` も更新する。
2. fixture変更時は `make api-cli-parity` を実行して同値性を確認する。
