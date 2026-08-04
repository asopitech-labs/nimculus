# Codex ブリーフ: ターミナル配色を Zed からクローン

ゴールは **Zed の UI/UX 完全再現**。今回は統合ターミナルの配色。値は
`references/zed/assets/themes/one/one.json` の `terminal.*` から取得済み（下記）。
macOS のみ。`DEVELOPMENT_GUIDELINES.md` 厳守。`nimble clean` 禁止。コミットしない。

## Zed の実値

**One Dark**
```
background #282c34   foreground #abb2bf   bright_foreground #dce0e5   dim_foreground #636d83
ansi.black #282c34  red #e06c75  green #98c379  yellow #e5c07b  blue #61afef
     magenta #c678dd  cyan #56b6c2  white #abb2bf
bright: black #636d83 red #EA858B green #AAD581 yellow #FFD885 blue #85C1FF
        magenta #D398EB cyan #6ED5DE white #fafafa
dim:    black #3b3f4a red #a7545a green #6d8f59 yellow #b8985b blue #457cad
        magenta #8d54a0 cyan #3c818a white #8f969b
```

**One Light**
```
background #fafafa   foreground #2a2c33   bright_foreground #2a2c33   dim_foreground #bbbbbb
ansi.black #000000  red #de3e35  green #3f953a  yellow #d2b67c  blue #2f5af3
     magenta #950095  cyan #0997b3  white #bbbbbb
bright: black #000000 red #de3e35 green #3f953a yellow #d2b67c blue #2f5af3
        magenta #a00095 cyan #0bbcd6 white #ffffff
dim:    black #555555 red #9c2b26 green #2b6927 yellow #a48c5a blue #2140ab
        magenta #6a006a cyan #0a7b92 white #888888
```

## 実装

1. ターミナルの ANSI 16 色（通常/bright/dim）と背景・前景を、上記 Zed 値へ置き換える
   （ライト/ダークで切り替え）。テーマ設定（`settings.nim` の ThemeColors か、macOS 側の
   terminal 配色テーブル）に組み込み、既存のテーマ切替に追従させる。
2. ターミナルのフォント・行高も、エディタと同じ Zed 準拠の設定に合わせる
   （Zed の `terminal.font_size` / `line_height` が default.json にあればそれに従う）。
3. カーソル・選択色もターミナル用の役割色に合わせる。

## 検証（必須・ライトとダーク）
```sh
nimble format  > /tmp/nimculus-fmt.log   2>&1
nimble lint    > /tmp/nimculus-lint.log  2>&1 || { tail -n 60 /tmp/nimculus-lint.log; exit 1; }
nimble test    > /tmp/nimculus-test.log  2>&1 || { tail -n 80 /tmp/nimculus-test.log; exit 1; }
nimble build   > /tmp/nimculus-build.log 2>&1 || { tail -n 40 /tmp/nimculus-build.log; exit 1; }
```
- **必ず `open build/macos/Nimculus.app` で起動し、ターミナルパネルを実際に開いて
  出力を表示させるところまで確認**し、新しい
  `~/Library/Logs/DiagnosticReports/Nimculus-*.ips` が出ないこと。
- ANSI 色テーブルの回帰テストを追加。`DESIGN_DECISIONS.md` に出典を記録。
- `nimble clean` 禁止。コミットしない。
