# Thin, memorable wrappers. The actual logic lives in the scripts under
# tools/ so it can be read, tested and invoked without `make` too.
#
# VM golden-image targets (docs/MACOS_UI_TEST_GUIDELINES.md §0) are the only
# ones defined here so far. Each wraps tools/vm_golden_image.sh, which is
# idempotent by design: re-running any target after a failure resumes rather
# than starting over, and nothing here deletes the golden image except
# vm-recreate, which only runs when you ask for it.
.PHONY: vm-status vm-verify vm-provision vm-recreate

## Non-destructive: does the golden image exist, and what state is it in.
vm-status:
	tools/vm_golden_image.sh status

## Non-destructive: boot a disposable clone of the golden image and confirm
## `nimble packageMacos` actually resolves and builds - the same command
## tools/ui_test.sh depends on for every real run.
vm-verify:
	tools/vm_golden_image.sh verify

## Idempotent: create the golden image if it is missing, then (re-)apply
## every setup step (packages, quarantine removal, settings, first-run
## dialogs, nimble package cache warm-up). Safe to re-run after a partial
## failure. Never deletes an existing image.
vm-provision:
	tools/vm_golden_image.sh provision

## Explicit recovery path: delete the existing golden image if present, then
## provision a fresh one. Use this when `make vm-verify` fails and
## `make vm-provision` alone does not fix it (e.g. the image's own disk is
## corrupted, not just missing a step).
vm-recreate:
	tools/vm_golden_image.sh recreate
