# Nimculus 作業ルール

## コーディングとコードレビューは codex に任せる

実装とコードレビューは **codex** が行う。Claude は自分でコードを書かず、次を担当する:

- 何を作るかの決定（Zed の参照実装 `references/zed` を読み、移植すべき構造を特定する）
- codex への指示（対象ファイル、参照する Zed のコード、受け入れ条件）
- **実測による検証**（codex の「直った」報告は証拠にならない。自分で測る）
- 測定値を添えたコミット

codex の呼び出しはバックグラウンド実行時に stdin で固まるので、`< /dev/null` を
必ず付ける（付け忘れて 4 時間ハングした実績あり）。

```bash
codex exec "<指示>" < /dev/null
```

指示には**受け入れ条件を数値で書く**こと。「速くして」ではなく
「`tools/scroll_cost.sh 40` で Zed の 10.00–10.50ms に対し 12ms 以下」のように書く。

## 完了判定

- UI パリティ: [`docs/UI_PARITY_ACCEPTANCE.md`](docs/UI_PARITY_ACCEPTANCE.md) が正
- 測定手順と踏んだ罠: [`docs/UI_PARITY_HANDOFF.md`](docs/UI_PARITY_HANDOFF.md)
- **未測定の項目は「未完了」として扱う**
