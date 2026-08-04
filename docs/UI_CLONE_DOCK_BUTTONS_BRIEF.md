# Codex ブリーフ: アクティビティバーを廃し Zed のドックボタン方式へ

ゴールは **Zed の UI/UX 完全再現**。Zed には Nimculus のような**左端の縦アクティビティ
バーが存在しない**。Zed はパネルを **ステータスバーの PanelButtons**（`workspace/src/dock.rs`
の `PanelButtons`、`status_bar.rs` に登録）で開閉する。これが最後の構造的差分。
macOS のみ。`DEVELOPMENT_GUIDELINES.md` 厳守。`nimble clean` 禁止。コミットしない。

## Zed の方式

- `crates/workspace/src/dock.rs`: 各 Panel は `icon()` / `icon_tooltip()` /
  `icon_label()` を持ち、`PanelButtons` がドックごとにアイコンボタンを並べる。
- そのボタン群は**ステータスバー**に置かれる（左ドック用は左側、右ドック用は右側）。
- クリックでそのパネルをトグル。アクティブなパネルのボタンは強調。
- 左端に常設の縦バーは無い。

## 実装

1. **左端の縦アクティビティバー（`NimculusActivityBar`）を廃止**する。
2. 代わりに **ステータスバーにドックパネルのトグルボタン**を置く（Zed 同様）。
   Nimculus のパネル（Files / Search / Outline / Git / Terminal / Debug）それぞれに
   アイコン＋tooltip を与え、クリックでトグル、アクティブなものを強調する。
   左ドックのパネル群はステータスバー左側、下ドック（Terminal 等）は右側など、
   Zed の配置規則に合わせる。
3. アクティビティバーが占めていた幅を解放し、Files パネルとエディタの左右関係・
   ヒットテスト・リサイズを新レイアウトへ整合させる（`presentedRegionAt` など）。
4. 既存のパネル切替コマンド・キーボードショートカット・AX・セッション復元を壊さない。
5. ライト/ダーク両対応。ghost ボタン様式・役割色を使う。

## 検証（必須・ライトとダーク）
```sh
nimble format  > /tmp/nimculus-fmt.log   2>&1
nimble lint    > /tmp/nimculus-lint.log  2>&1 || { tail -n 60 /tmp/nimculus-lint.log; exit 1; }
nimble test    > /tmp/nimculus-test.log  2>&1 || { tail -n 80 /tmp/nimculus-test.log; exit 1; }
nimble build   > /tmp/nimculus-build.log 2>&1 || { tail -n 40 /tmp/nimculus-build.log; exit 1; }
```
- **必ず `open build/macos/Nimculus.app` で起動し、新しいトグルボタンで各パネル
  （Files / Search / Outline / Git / Terminal）を実際に開閉するところまで確認**する。
  新しい `~/Library/Logs/DiagnosticReports/Nimculus-*.ips` が出ないこと。
- レイアウト/ヒットテストの回帰テストを更新・追加する。
- `DESIGN_DECISIONS.md` に出典と、アクティビティバー廃止の理由を記録。
- `nimble clean` 禁止。コミットしない。
