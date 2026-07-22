# Nimculus

Nimculus は、NimNUI を UI 基盤とする GPU ネイティブコードエディタです。初期開発の主対象は Apple Silicon 搭載 macOS です。

## 開発環境

- macOS on Apple Silicon
- Nim 2.x
- Nimble
- Cocoa / Metal / QuartzCore

## ビルドとテスト

```sh
nimble build
nimble test
nimble benchmark
```

macOSの実アプリ起動から初回ready/idle到達までを測る場合は、専用の一時
ビルドとHOMEを使う次の計測を実行する。GUIセッションが利用できるApple
Silicon macOSで実行すること。

```sh
bash scripts/benchmark_cold_start.sh
```

既存の実行ファイルを使う場合は `NIMCULUS_BINARY=/path/to/Nimculus`、
反復回数は `NIMCULUS_COLD_START_RUNS=10`、1回あたりのtimeoutは
`NIMCULUS_COLD_START_TIMEOUT_SECONDS=30` で指定できる。

M1 の最小縦切りは macOS ウィンドウ、`CAMetalLayer`、Metal の clear / rectangle 描画、Retina 対応、基本入力イベントログです。

## ドキュメント

- [アーキテクチャ](./ARCHITECTURE.md)
- [設計判断](./DESIGN_DECISIONS.md)
- [ロードマップ](./ROADMAP.md)
- [開発ガイドライン](./DEVELOPMENT_GUIDELINES.md)
- [実装レビュー](./IMPLEMENTATION_REVIEW.md)
