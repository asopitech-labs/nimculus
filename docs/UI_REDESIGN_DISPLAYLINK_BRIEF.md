# Codex ブリーフ: ProMotion / CADisplayLink フレームペーシング（契約保持）

目的: 描画をイベント駆動の同期 drawFrame から、**dirty ゲート付き display-link ペーシング**へ
移し、Apple Silicon の ProMotion で最大 120Hz に乗せつつ、急速スクロール時の描画をコアレス
する。**既存のフレーム計数・診断の契約を絶対に壊さないこと。** macOS のみ。
`DEVELOPMENT_GUIDELINES.md` 厳守（層分離・UI スレッド非ブロッキング・端末に配慮したログ・
専用 nimcache・format/lint・tooltip/AX 維持・既存テスト/contract 不破壊）。`nimble clean`
禁止。コミットしない。主対象: `src/nimnui/platform/macos/macos_platform.m`。

## 守るべき契約（最重要）

現状:
- `drawFrame`（L6700 付近）は `presentDrawable` 後に `recordFrameTimingSample(...)` と
  `g_metrics.frame_count++`（L6938 付近）を行う。「フレーム」= 実際に present された描画。
- `scripts/benchmark_cold_start.sh` は起動後に **`frames > 0`**（最低 1 フレーム描画）を要求。
- `scripts/benchmark_soak.sh` は `max_frames > 0` かつ frame 診断（`frame_samples`,
  `frame_p95_ms`, `frame_over_60hz_budget`）の存在を要求。
- 正確なフレーム数や「1 入力 = 1 フレーム」は要求されない。

したがって: **display-link 非稼働の文脈（ヘッドレス、ユニット/契約テスト、起動直後、
ウィンドウ不可視）では、再描画要求は従来どおり同期 `drawFrame` に落ちる**こと。これにより
frame_count・frame timing・診断の挙動がテストで一切変わらない。live GUI でのみ display link
が唯一の描画者になる。

## 実装

1. `NimculusMetalView` に **dirty フラグ** と `requestRedraw`（= フラグを立てる）を追加。
   - `requestRedraw`: display link が稼働中なら dirty フラグを立てて戻る（描画は次 vsync）。
     display link が**非稼働なら即座に `drawFrame` を同期呼び出し**（従来挙動を完全維持）。
2. **display link を追加**（Apple Silicon 前提、ProMotion 対応）:
   - 可能なら macOS 14+ の `-[NSView displayLinkWithTarget:selector:]`（または
     `CAMetalDisplayLink`）を使い、`preferredFrameRateRange` を
     `CAFrameRateRangeMake(60, 120, 120)`（または画面の `maximumFramesPerSecond`）に設定。
   - 14 未満のフォールバックが必要なら `CVDisplayLink`。無ければ display link を使わず
     従来の同期経路のまま（機能低下として許容、契約は保持）。
   - コールバック（メインスレッドで実行）: dirty フラグが立っていれば `drawFrame` を呼び、
     フラグをクリア。立っていなければ何もしない（描画ゼロ＝アイドル時のフレーム数は現状同）。
3. **既存の直接 `drawFrame` 呼び出し（約 43 箇所）のうち、インタラクティブ/設定反映系を
   `requestRedraw` へ置換**。急速に連続し得る経路（スクロール/ポインタ由来の再描画、
   `nimculus_platform_*` の状態反映）を対象にする。**初期化・cold-start の最初の描画・
   検証用 API が同期描画に依存している箇所は同期のまま**にして契約を保つ（不確かなら同期を
   残す方に倒す）。
4. **ライフサイクル**: ウィンドウが可視/key になったら display link を開始、miniaturize/
   occluded/close で停止して電力を節約。ただし cold-start の初回フレームは必ず描画されること
   （開始直後に dirty を立てて 1 フレーム出す等）。ウィンドウが無い/ヘッドレスでは開始しない。
5. `presentDrawable`・`recordFrameTimingSample`・`g_metrics.frame_count++` の意味は不変。
   drawFrame 自体のダメージ（dirty-region）描画ロジックは変更しない。
6. 二重描画を避ける: display link 稼働中は同経路が同期 drawFrame とフラグの両方を走らせない。

## 検証（必須）

```sh
nimble format  > /tmp/nimculus-fmt.log   2>&1
nimble lint    > /tmp/nimculus-lint.log  2>&1 || { tail -n 60 /tmp/nimculus-lint.log; exit 1; }
nimble test    > /tmp/nimculus-test.log  2>&1 || { tail -n 80 /tmp/nimculus-test.log; exit 1; }
nimble build   > /tmp/nimculus-build.log 2>&1 || { tail -n 40 /tmp/nimculus-build.log; exit 1; }
```

- 全て通す。特に `test_platform_contract`, `test_platform_headless`, 及びフレーム/入力
  レイテンシ関連の検証（`nimculus_platform_validate_*`、frame timing stats）が緑であること。
- 変更を `DESIGN_DECISIONS.md` に追記（契約保持の設計理由を含む）。
- `nimble clean` 禁止。コミットしない。GUI 実機スモーク（cold_start/soak）の起動は不要
  （人間が別途実行して frames>0 を確認する）。

## やらないこと

- frame_count/診断のセマンティクス変更、ダメージ描画ロジックの書き換え、
  Windows/Linux/headless バックエンド改変、command/contract/テストの破壊、`nimble clean`。
