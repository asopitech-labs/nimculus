#!/usr/bin/env bash
set -euo pipefail

# Static UI inventory extractor for the checked-in Zed reference. It is
# intentionally syntax-oriented: the result is a review list, not a Rust
# parser. Run from the repository root.
zed_root="${1:-references/zed}"
ui_dirs=(
  "$zed_root/crates/workspace/src"
  "$zed_root/crates/editor/src"
  "$zed_root/crates/project_panel/src"
  "$zed_root/crates/terminal_view/src"
  "$zed_root/crates/git_ui/src"
  "$zed_root/crates/search/src"
)

printf '%s\n' '# Zed UI element extraction'
printf '%s\n' "Source: \`$zed_root\`" ''

printf '%s\n' '## Status-bar registrations'
rg -n 'status_bar\.add_(left|right)_item' "$zed_root/crates/zed/src/zed.rs" \
  | sed -E 's/^.*status_bar\.add_(left|right)_item\(([^,]+).*/- \1: \2/'
printf '\n'

printf '%s\n' '## Status-item implementations'
rg -l 'impl (workspace::)?StatusItemView for|impl StatusItemView for' \
  "$zed_root/crates" --glob '*.rs' | sort \
  | sed "s#^$zed_root/##; s#^#- \`#; s#\$#\`#"
printf '\n'

printf '%s\n' '## Button and icon-button identifiers'
rg -o '((IconButton|Button)::new\([^\n]+)' "${ui_dirs[@]}" \
  --glob '*.rs' 2>/dev/null \
  | sed -E 's#^[^:]+:[0-9]+:##' | sort -u
printf '\n'

printf '%s\n' '## Context-menu action labels'
rg -o '\.(action|entry)\("[^"]+' "${ui_dirs[@]}" \
  --glob '*.rs' 2>/dev/null \
  | sed -E 's#.*\.(action|entry)\("##' | sort -u
