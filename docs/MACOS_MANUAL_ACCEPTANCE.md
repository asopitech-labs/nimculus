# macOS 手動受け入れ確認

この手順は、CIでは代替できない物理入力機器・macOS入力ソース・画面構成を必要とする
M1〜M5の最終確認用である。Apple Silicon macOSのGUIログインセッションで、最新の
`main` をビルドして実行する。

```sh
nimble build
./src/nimculus/main
```

各項目は実施日、macOSバージョン、ディスプレイ構成、結果（pass/fail）をissueまたは
リリース記録へ残す。fail時は再現操作とConsoleログを添付し、ロードマップを完了扱いに
しない。

## M1: window, display, and trackpad

1. `View > Enter Full Screen` を実行し、専用spaceへの遷移後にMetal描画、キーボード
   入力、`Esc`または同じmenuでの復帰を確認する。
2. 外部ディスプレイを接続し、Nimculusのwindowを両方の画面へ移動する。各画面で
   Retina/non-Retina scale、resize後の描画、入力位置を確認する。
3. 内蔵trackpadで短いscroll、慣性scroll、方向反転を行う。editorとterminal scrollback
   の双方で、pixel scrollが滑らかに累積し、通常mouse wheelが1操作ごとに論理行を移動
   することを確認する。

## M2: UI clipping and split panes

1. UI galleryでscroll containerを端までscrollし、child contentがviewport外へ描画・
   hit-testされないことを確認する。
2. Split Editorを開き、dividerを両端近くまでdragする。両paneでクリック、drag選択、
   scroll、Command shortcutが独立して動くことを確認する。

## M3/M5: Japanese input and save

1. macOSの入力ソースを日本語IMEへ切り替え、主paneと副paneの両方で日本語を入力する。
   compositionの下線、候補window、候補確定・取消がそれぞれのcaret位置に従うことを
   確認する。
2. 日本語・絵文字を含む本文とファイル名を作成し、Save Asで保存する。再open後に本文、
   改行コード、選択、文字表示が失われないことを確認する。
3. 外部エディタで同ファイルを変更し、Nimculus側の非同期変更sheetでreloadとkeep editing
   の両方を確認する。

## 記録の完了条件

- 全項目がpassである。
- 実施環境がApple Silicon macOSである。
- M1の複数monitor項目は、少なくとも2画面の実構成でpassしている。
- M3/M5のIME項目は、日本語入力ソースを実際に選択してpassしている。

この手順はDeveloper ID/notarizationを要求しない。署名・notarizationの外部資格情報は
M11のrelease acceptanceで別途確認する。
