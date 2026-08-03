# Zed UI Element Inventory

This is the mechanical UI inventory used for the macOS implementation review.
It is generated from the local reference at `references/zed`, then annotated
with the Nimculus implementation state. Regenerate the raw extraction with:

```sh
tools/extract_zed_ui_inventory.sh
```

The extraction is intentionally based on stable UI construction sites in Zed
(`StatusItemView`, `Button::new`, `IconButton::new`, and context-menu action
builders). It catches omissions that a screenshot-only comparison misses.

## Zed status bar

Zed registers these status items in `crates/zed/src/zed.rs`:

| Side | Element | Zed source | Nimculus state |
| --- | --- | --- | --- |
| left | Project search | `crates/search/src/search_status_button.rs` | Missing |
| left | Language server | `crates/language_tools/src/lsp_button.rs` | Present: iconized LSP state in footer |
| left | Diagnostics summary | `crates/diagnostics/src/items.rs` | Present: error/warning counts or clean checkmark |
| left | Active file name | `crates/workspace/src/active_file_name.rs` | N/A: breadcrumb remains the document identity |
| left | Git blame | `crates/git_ui/src/blame_ui.rs` | Missing |
| left | Merge conflicts | `crates/git_ui/src/conflict_view.rs` | Missing |
| left | Activity indicator | `crates/activity_indicator/src/activity_indicator.rs` | Missing |
| right | Edit predictions | `crates/edit_prediction_ui/src/edit_prediction_button.rs` | N/A for current scope |
| right | Buffer encoding | `crates/encoding_selector/src/active_buffer_encoding.rs` | Present: clickable UTF-8 entry |
| right | Buffer language | `crates/language_selector/src/active_buffer_language.rs` | Present: clickable detected-language entry |
| right | Toolchain | `crates/toolchain_selector/src/active_toolchain.rs` | Missing |
| right | Line ending | `crates/line_ending_selector/src/line_ending_indicator.rs` | Present: clickable LF/CRLF entry |
| right | Vim mode | `crates/vim/src/mode_indicator.rs` | N/A unless Vim mode enabled |
| right | Cursor position | `crates/go_to_line/src/cursor_position.rs` | Present: clickable structured entry |
| right | Image information | `crates/image_viewer/src/image_info.rs` | N/A for text editor |

Zed also gives status items a right-click menu with `Hide Button` and exposes
the bar as a keyboard-navigable toolbar. Nimculus preserves its existing
Status Bar Settings / Hide menu, native button tooltips, and accessibility
labels. Nimculus deliberately excludes Zed's activity-bar panel toggles from
the footer because those destinations already belong to the left activity
bar.

## Tabs and the information below/around tabs

Zed's `crates/workspace/src/pane.rs` and `crates/ui/src/components/tab.rs`
contain these user-visible elements:

- Back and forward navigation buttons.
- A scrollable tab strip with active, inactive, pinned, preview, dirty, and
  read-only states.
- File icon, read-only lock, dirty indicator, close button, and pin/unpin
  control.
- Drag reorder and drag-to-split targets.
- Open-tabs list/disclosure menu.
- New-item menu: New File, Open File, Search Project, Search Symbols, New
  Terminal, and New Center Terminal.
- Split menu: Split Right, Split Left, Split Up, Split Down.
- Pane zoom control.
- Tab tooltip with path/read-only metadata.
- Tab context menu: Close, Close Others, Close Multibuffers, Close Left,
  Close Right, Close Clean, Close All, Pin/Unpin, Unpin All, Copy Path,
  Reveal in Project Panel, and item-specific actions.

Nimculus now has a measured content-width strip, active state, dirty marker,
active/hover close target, native SF Symbol back/forward/open-tabs/new/split/
zoom buttons, open-tabs menu, drag reorder, pin/unpin, copy path, Reveal in
Finder, tab cleanup actions, and tab-bar new/split menus. The pane zoom action
is exposed through the same command entry point and remains dependent on the
workspace zoom state. On macOS the activity bar and project panels follow
Zed's default left-side order.

The macOS Files, Search, and Git panels use a single-row title/action header:
the title is left-aligned, the 24pt native actions are right-aligned, and Git's
Changes/History/Branches navigation remains directly below that header.

## Context menus

The mechanically extracted applicable Zed action labels include:

### Editor text context menu

Run to Cursor, Evaluate Selection, Go to Definition, Go to Declaration, Go to
Type Definition, Go to Implementation, Find All References, Rename Symbol,
Format Buffer, Format Selections, Show Code Actions, Add to Agent Thread, Cut,
Copy, Copy and Trim, Paste, Reveal in Finder, Open Markdown Preview, Open SVG
Preview, Open in Terminal, and Copy Permalink.

Nimculus now has an editor-text right-click menu with the applicable navigation,
LSP, formatting, editing, terminal, and Finder actions.

### File tree context menu

New File, New Folder, Reveal in Finder, Open in Default App, Open in Terminal,
Open Markdown Preview, Find in Folder, Unfold Directory, Fold Directory,
Compare Marked Files, Cut, Copy, Duplicate, Paste, Undo, Redo, Download,
Copy Path, Copy Relative Path, Restore File, Add to `.gitignore`, Add to
`.git/info/exclude`, View History, Rename, Trash, Delete, Add Folders to
Project, Remove from Project, Expand All, and Collapse All.

### Git context menus

Zed exposes staged/unstaged hunk actions, restore actions, commit SHA/ref copy,
open/view diff, history, graph, and branch actions. Nimculus has basic change,
history, and branch menus but not the full item/action set.

## Extraction sources

- `references/zed/crates/zed/src/zed.rs`
- `references/zed/crates/workspace/src/status_bar.rs`
- `references/zed/crates/workspace/src/pane.rs`
- `references/zed/crates/workspace/src/dock.rs`
- `references/zed/crates/editor/src/mouse_context_menu.rs`
- `references/zed/crates/editor/src/element/header.rs`
- `references/zed/crates/project_panel/src/project_panel.rs`
- `references/zed/crates/ui/src/components/tab.rs`
- `references/zed/crates/ui/src/components/tab_bar.rs`

## Completion gate for this inventory

- Every applicable status item is visible in a two-cluster structured footer.
- Footer items have tooltips and action handlers where Zed has them.
- Editor text, file tree, Git rows, history rows, branch rows, tabs, and
  status items all have an explicit context-menu contract.
- The inventory is regenerated after each UI review; implementation status is
  not inferred from internal service code alone.
