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

M1 の最小縦切りは macOS ウィンドウ、`CAMetalLayer`、Metal の clear / rectangle 描画、Retina 対応、基本入力イベントログです。

## ドキュメント

- [アーキテクチャ](./ARCHITECTURE.md)
- [設計判断](./DESIGN_DECISIONS.md)
- [ロードマップ](./ROADMAP.md)
- [開発ガイドライン](./DEVELOPMENT_GUIDELINES.md)
- [実装レビュー](./IMPLEMENTATION_REVIEW.md)
