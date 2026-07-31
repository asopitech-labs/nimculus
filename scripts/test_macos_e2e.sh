#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT="${TMPDIR:-/tmp}/nimculus-macos-e2e-$$"
OUT_DIR="$TMP_ROOT/package"
COLD_RUNS="${NIMCULUS_E2E_COLD_START_RUNS:-3}"
SOAK_SECONDS="${NIMCULUS_E2E_SOAK_SECONDS:-20}"
SOAK_INTERVAL_SECONDS="${NIMCULUS_E2E_SOAK_INTERVAL_SECONDS:-5}"
SOAK_TIMEOUT_SECONDS="${NIMCULUS_E2E_SOAK_TIMEOUT_SECONDS:-$((SOAK_SECONDS + 20))}"
KEEP_ARTIFACTS="${NIMCULUS_E2E_KEEP_ARTIFACTS:-0}"
# Native panel sheets are covered by the dedicated GUI runner. The combined
# E2E may execute inside an isolated process without macOS's panel auxiliary
# XPC service; keep that process failure from masking the application-level
# release gate. Set to 0 on a runner that vends those services.
export NIMCULUS_SKIP_NATIVE_SHEET_CONTRACTS="${NIMCULUS_E2E_SKIP_NATIVE_SHEET_CONTRACTS:-1}"

GENERATED_BINARIES=(
  src/nimculus/main
  tests/test_platform_headless
  tests/test_macos_file_panels
  tests/test_macos_modal_sheets
  tests/test_macos_application_alert_sheet
  tests/test_platform_contract
  tests/test_ui_text
  tests/test_editor
  tests/test_editor_fuzz
  tests/test_workspace
  tests/test_tree_sitter
  tests/test_syntax
  tests/test_editor_syntax
  tests/test_lsp
  tests/test_lsp_editor_bridge
  tests/test_git_gutter
  tests/test_git_service
  tests/test_terminal
  tests/test_task_service
  tests/test_settings
  tests/test_update_service
  tests/test_workspace_watcher
  tests/bench_m20
  tests/bench_platform
  tests/bench_editor
  tests/bench_large_editor
  tests/bench_buffer_strategies
  tests/bench_syntax
  tests/bench_workspace
)

cleanup() {
  if [[ "$KEEP_ARTIFACTS" != "1" ]]; then
    rm -rf "$TMP_ROOT"
    rm -rf "$ROOT_DIR/.nimcache"
    for binary in "${GENERATED_BINARIES[@]}"; do
      rm -f "$ROOT_DIR/$binary"
    done
  else
    printf 'macos_e2e_artifacts\t%s\n' "$TMP_ROOT"
  fi
}
trap cleanup EXIT

positive_integer() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

phase() {
  printf 'macos_e2e_phase\t%s\n' "$1"
}

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "macOS E2E must run on Darwin" >&2
  exit 2
fi
if ! positive_integer "$COLD_RUNS" || ! positive_integer "$SOAK_SECONDS" ||
    ! positive_integer "$SOAK_INTERVAL_SECONDS" || ! positive_integer "$SOAK_TIMEOUT_SECONDS"; then
  echo "macOS E2E run counts and timeouts must be positive integers" >&2
  exit 2
fi
if (( SOAK_TIMEOUT_SECONDS <= SOAK_SECONDS )); then
  echo "NIMCULUS_E2E_SOAK_TIMEOUT_SECONDS must exceed NIMCULUS_E2E_SOAK_SECONDS" >&2
  exit 2
fi

mkdir -p "$TMP_ROOT"

if [[ "${NIMCULUS_E2E_SKIP_DEPS:-0}" != "1" ]]; then
  phase dependencies
  (
    cd "$ROOT_DIR/ci"
    nimble install --depsOnly -y
  )
fi

phase build
(
  cd "$ROOT_DIR"
  nimble build
)

phase native-contracts
for test_name in test_macos_file_panels test_macos_modal_sheets \
    test_macos_application_alert_sheet test_platform_contract; do
  (
    cd "$ROOT_DIR"
    if [[ "$NIMCULUS_SKIP_NATIVE_SHEET_CONTRACTS" == "1" ]]; then
      # Isolated jobs intentionally omit AppKit's auxiliary XPC services.
      # The test suite skips only the sheet/physical-IME/Metal contracts in
      # that mode; forcing NIMCULUS_REQUIRE_NATIVE_GUI would contradict it.
      nim c --mm:arc --nimcache:"$TMP_ROOT/$test_name" \
        -r --path:src "tests/$test_name.nim"
    else
      NIMCULUS_REQUIRE_NATIVE_GUI=1 \
        nim c --mm:arc --nimcache:"$TMP_ROOT/$test_name" \
          -r --path:src "tests/$test_name.nim"
    fi
  )
done

phase unit-and-integration
(
  cd "$ROOT_DIR"
  nimble test
)

phase benchmarks
(
  cd "$ROOT_DIR"
  nimble benchmark
)

printf 'E2E 日本語🙂\r\n' > "$TMP_ROOT/日本語🙂.nim"
phase cold-start
(
  cd "$ROOT_DIR"
  NIMCULUS_COLD_START_RUNS="$COLD_RUNS" \
    NIMCULUS_COLD_START_TIMEOUT_SECONDS=30 \
    NIMCULUS_COLD_START_PATH="$TMP_ROOT/日本語🙂.nim" \
    bash scripts/benchmark_cold_start.sh
)

phase soak
(
  cd "$ROOT_DIR"
  NIMCULUS_SOAK_SECONDS="$SOAK_SECONDS" \
    NIMCULUS_SOAK_INTERVAL_SECONDS="$SOAK_INTERVAL_SECONDS" \
    NIMCULUS_SOAK_TIMEOUT_SECONDS="$SOAK_TIMEOUT_SECONDS" \
    bash scripts/benchmark_soak.sh
)

phase package
(
  cd "$ROOT_DIR"
  NIMCULUS_ALLOW_ADHOC=1 NIMCULUS_OUT_DIR="$OUT_DIR" bash scripts/package_macos.sh
  NIMCULUS_OUT_DIR="$OUT_DIR" \
    NIMCULUS_COLD_START_RUNS=1 \
    NIMCULUS_COLD_START_TIMEOUT_SECONDS=30 \
    bash scripts/verify_macos_package.sh
)

if [[ "${NIMCULUS_E2E_GUI_WORKFLOWS:-0}" == "1" ]]; then
  phase gui-workflows
  (
    cd "$ROOT_DIR"
    bash scripts/test_macos_gui_workflows.sh
  )
fi

printf 'macos_e2e_complete\tcold_runs=%s\tsoak_seconds=%s\n' "$COLD_RUNS" "$SOAK_SECONDS"
