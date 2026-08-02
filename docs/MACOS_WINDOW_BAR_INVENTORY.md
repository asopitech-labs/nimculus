# macOS Window Bar and Workspace UX Inventory

This inventory is the implementation checklist for the macOS window chrome
and the first workspace rows. It is based on the local Zed reference in
`references/zed` and the packaged Nimculus screenshot review.

## Window-level chrome

| Area | Zed reference | Nimculus implementation | State |
| --- | --- | --- | --- |
| Traffic lights | Native macOS controls positioned in the transparent titlebar | Native AppKit controls retained by `NSWindow` | Done |
| Titlebar surface | App-owned, transparent/full-size content | `NSFullSizeContentView` with dark `NimculusTitlebarView` | Done |
| Window title | Hidden native title; workspace context is rendered by the app | Workspace name rendered in the titlebar | Done |
| Drag region | App-owned titlebar drag behavior | Titlebar drag delegates to `performWindowDragWithEvent:` | Done |
| Double-click zoom | Titlebar double-click zoom | Titlebar double-click calls `performZoom:` | Done |
| Minimize / zoom / fullscreen | Native Window actions | AppKit Window menu and native window controls | Done |
| Minimum window size | 360 × 240 logical points | 360 × 240 logical points | Done |

## Titlebar content

| Area | User-visible function | Nimculus behavior | State |
| --- | --- | --- | --- |
| Workspace name | Identifies the open project | First segment of the editor context, with `Nimculus` fallback | Done |
| Git branch | Shows current repository branch | Async, cancellable Git lookup; shows branch or `No Git branch` | Done |
| Branch action | Opens branch navigation | Accessible native button opens Git Branches | Done |
| Detached HEAD | Communicates non-branch state | Displays `(detached)` | Done |
| Document breadcrumb | Identifies current file location | Rendered once in the editor header below the titlebar | Done |
| Duplicate breadcrumb prevention | Avoids repeated location information | Titlebar deliberately does not render document breadcrumb | Done |
| Account / sign-in | Zed-specific account entry | Not applicable: Nimculus has no account service | N/A |

## Workspace entry points below the titlebar

| Area | Nimculus entry point | State |
| --- | --- | --- |
| Files | Persistent activity-bar Files button and project tree | Done |
| Search | Activity-bar Search button and cancellable search panel | Done |
| Outline | Activity-bar Outline button and symbol panel | Done |
| Git | Activity-bar Git button plus Changes / History / Branches tabs | Done |
| Terminal | Activity-bar Terminal button and PTY panel | Done |
| Split | Split action in the editor header and command routing | Done |
| Debug | Activity-bar Debug entry point | Done |
| Main menu | File, Edit, View, Agent, Extensions, Window | Done |

## Verification checklist

- Screenshot shows one workspace name, one Git branch badge, and one document
  breadcrumb.
- Clicking the branch badge opens Git Branches without opening a modal dialog.
- Branch lookup does not block the UI thread.
- Branch and titlebar controls are exposed as native accessibility elements.
- Editor text begins below the titlebar and remains inside its right and bottom
  viewport boundaries.
