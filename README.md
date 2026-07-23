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
`.app` bundle、ビルドキャッシュ、HOMEを使う次の計測を実行する。raw
executableを`NIMCULUS_BINARY`で指定した場合も、LaunchServicesのbundle
ライフサイクルを再現する一時`.app`へ包んで起動する。GUIセッションが利用
できるApple Silicon macOSで実行すること。

```sh
bash scripts/benchmark_cold_start.sh
```

既存の実行ファイルを使う場合は `NIMCULUS_BINARY=/path/to/Nimculus`（raw
実行ファイルは一時`.app`へ自動的に包む）、
反復回数は `NIMCULUS_COLD_START_RUNS=10`、1回あたりのtimeoutは
`NIMCULUS_COLD_START_TIMEOUT_SECONDS=30` で指定できる。

Developer ID notarizationは、Appleのkeychain profile（`APPLE_NOTARY_PROFILE`）
またはApp Store Connect API key（`APPLE_NOTARY_KEY`、
`APPLE_NOTARY_KEY_ID`、`APPLE_NOTARY_ISSUER_ID`）を優先して利用できる。
従来の`APPLE_ID`、`APPLE_TEAM_ID`、`APPLE_APP_SPECIFIC_PASSWORD`も利用可能だが、
資格情報をリポジトリへ保存してはならない。

GitHub ActionsでDeveloper ID配布を行う場合は、`macos-release.yml`を手動実行する。
証明書、証明書パスワード、署名ID、App Store Connect API keyはActions secretsへ登録し、
workflowがrunner一時keychainへ導入してstrictなstapler/Gatekeeper検証後にartifactを公開する。

Zedのreliability heartbeatを参考に、アプリのidle境界でresident memory、
live allocation、frame/inputを定期記録するsoak計測は次で実行する。既定は
8時間で、GUIセッションが利用できるmacOSまたはWindowsで実行する。

```sh
bash scripts/benchmark_soak.sh
```

短い動作確認では `NIMCULUS_SOAK_SECONDS=60`、記録間隔は
`NIMCULUS_SOAK_INTERVAL_SECONDS=10`、実行ファイルは
`NIMCULUS_BINARY=/path/to/Nimculus` で指定できる。
各サンプルの先頭値から最終値までの増加も検証する。既定の上限はresident
memoryが128MiB、live allocation blocksが50,000で、必要に応じて
`NIMCULUS_SOAK_MAX_RESIDENT_GROWTH_BYTES` と
`NIMCULUS_SOAK_MAX_LIVE_BLOCK_GROWTH` で調整できる。

M1 の最小縦切りは macOS ウィンドウ、`CAMetalLayer`、Metal の clear / rectangle 描画、Retina 対応、基本入力イベントログです。

## ドキュメント

- [アーキテクチャ](./ARCHITECTURE.md)
- [設計判断](./DESIGN_DECISIONS.md)
- [ロードマップ](./ROADMAP.md)
- [開発ガイドライン](./DEVELOPMENT_GUIDELINES.md)
- [実装レビュー](./IMPLEMENTATION_REVIEW.md)
