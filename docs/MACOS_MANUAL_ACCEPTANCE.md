# macOS E2E 受け入れ確認

この文書は、個別マイルストーンごとに手作業でGUIを確認するためのチェックリストではない。
M12（設定・テーマ・キーバインド）とM20の自動性能基準がそろった release candidate に対し、
Apple Silicon macOSのGUIログインセッションで一度に実施する、macOS版のE2E受け入れ手順である。

各マイルストーンではunit test、integration test、native Cocoa/Metal contract、self-hosted
macOS CIを完了条件とする。物理入力機器・日本語入力ソース・複数ディスプレイが必要な確認は、
後続の実装を止める個別ゲートにしない。

## 自動E2E証跡

2026-07-28に、Apple SiliconのGUIログイン済みself-hosted runnerで、commit
[`a3b1d1c`](https://github.com/asopitech-labs/nimculus/commit/a3b1d1c79fba37af6f6456828936c862277c7438)
の[macOS Release Candidate E2E](https://github.com/asopitech-labs/nimculus/actions/runs/30345469642)
が成功した。この実行は、全test、native Cocoa/Metal contract、benchmark、3回のcold-start、
20秒soak、adhoc署名DMGをmountした内部`.app`の起動を一つのself-hosted GUI実行で確認した。

この証跡は自動化できるrelease-candidate基準を満たす。一方で、物理日本語IME、trackpad、
複数ディスプレイ、実Language Serverの対話操作、2時間/8時間の連続利用、Developer ID署名・
notarizationは、この成功結果から完了とは主張しない。それらは利用可能な環境または資格情報で
同じ受け入れ記録へ追加する。

## 実行条件

- 対象はM12とM20の自動検証が成功した最新release candidateの`.app`またはDMG。
- Apple Silicon macOSのGUIログインセッションで実施する。
- LSPシナリオには、Nim / Rust / TypeScriptのいずれかの実Language Serverを用意する。
- 複数ディスプレイと内蔵trackpadは利用可能な実機で確認する。利用できないハードウェアは
  未実施理由を記録し、同じE2Eサイクルの他シナリオを止めない。

事前に自動証跡を確認する。

```sh
nimble macosE2E
```

`macosE2E`は全test、native Cocoa/Metal contract、benchmark、3回cold-start、短いsoak、
adhoc署名DMGのmount後起動を一つのログとして実行する。release acceptanceでは
`NIMCULUS_E2E_SOAK_SECONDS=28800 nimble macosE2E`を使い、同じE2E記録へ長時間結果を残す。

配布候補では、資格情報が利用可能な場合に`NIMCULUS_REQUIRE_NOTARIZATION=1`でパッケージ
検証も実行する。Developer ID / notarizationは機能E2Eとは別のrelease acceptanceである。

## 一連のE2Eシナリオ

### 1. 起動・window・入力

1. `.app`を起動し、Finderからファイルを開く。Retina画面でresize、最小化、最大化、
   full screenへの出入り後もMetal描画、キーボード、ポインター入力が維持されることを確認する。
2. 複数画面がある場合はwindowを各画面へ移動し、scale、描画、クリック位置を確認する。
3. trackpadでeditorとterminalの短いscroll、慣性scroll、方向反転を操作する。通常mouse
   wheelも各操作で論理行を移動することを確認する。

### 2. 編集・IME・ファイルライフサイクル

1. 日本語・絵文字を含むCRLFファイルを開く。主/副paneをsplitし、クリック、drag選択、
   Option単語移動、undo/redo、検索/置換、soft wrap、保存を連続して操作する。
2. macOS入力ソースを日本語IMEへ切り替え、両paneでcomposition、候補window、確定、取消を
   操作する。候補位置が各paneのcaretに追従することを確認する。
3. 日本語・絵文字を含む名前でSave Asし、再open後に本文、改行コード、selection、文字表示を
   確認する。外部エディタで同ファイルを変更し、ReloadとKeep Editingの両方を確認する。
4. 未保存文書を含むtab/windowを閉じ、Save / Don't Save / Cancelとsession recoveryを確認する。

### 3. ワークスペースと言語機能

1. Git repositoryをworkspaceとして開く。複数root、file tree、Quick Open、workspace search、
   検索cancel、ファイル作成/rename/delete、外部変更反映を一連で確認する。
2. Nim、Rust、TypeScriptまたはTSXを開き、Tree-sitterの色、bracket、fold、outline、
   syntax-aware selectionを確認する。
3. 実Language Serverでdiagnostics、completion、hover、definition、references、rename preview、
   formatting、code action、signature help、semantic tokens、inlay hintsを操作する。TSXでは
   `typescriptreact` language IDを使う設定で確認する。

### 4. Git・terminal・task・設定

1. Git status、inline diff、gutter stage/Option-unstage、hunk操作、commit、log、blame、
   checkout、cancelを確認する。
2. zsh terminalを複数開き、resize、scrollback、選択、copy/paste、日本語貼り付け、
   bracketed pasteを確認する。長時間taskを起動し、output / problem matcherとcancelを確認する。
3. `Cmd+,`でtheme、font、terminal shellを変更し、live reload、Light/Dark system appearance、
   keymapが現在のeditor/terminalへ反映されることを確認する。

### 5. 安定性・配布

1. 上記シナリオを含む通常利用を2時間以上継続し、crash、入力停止、継続的なメモリ増加がない
   ことを確認する。正式release前にはM20の8時間soakも同じ実行記録に追加する。
2. DMG候補ではinstall、起動、Finder Open With、file association、URL schemeを確認する。
   notarization済み候補ではGatekeeper経路も確認する。

## 記録と判定

一回のE2Eレポートに、commit SHA、macOS版、machine、display構成、入力機器、使用した
Language Server、各シナリオのpass/fail、失敗時の再現手順・Consoleログ・スクリーンショットを
残す。ハードウェア未保有による未実施はcoverageとして記録し、機能実装の後続マイルストーンを
停止しない。機能失敗はissue化し、該当する自動regression testを追加してから再実施する。
