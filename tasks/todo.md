# Add Opt/Shift Modifiers, Swipe Arrow Controls + Redesign Toolbar Editor

## Implementation

- [x] Add Opt, Shift, swipe button definitions to `ToolbarButton.swift`
  - New `.swipe` category
  - `opt`, `shift` sticky modifiers
  - `swipeAll`, `swipeHoriz`, `swipeVert` buttons
  - `stickyModifierIDs` and `swipeButtonIDs` sets
  - Updated `defaultButtons` with `.opt`
- [x] Refactor `KeyboardToolbarAccessoryView` for multi-modifier support
  - `ctrlActive: Bool` → `activeModifiers: Set<String>`
  - `applyModifiersIfNeeded` with xterm modifier codes (Path A: escape seqs, Path B: single bytes)
  - `insertXtermModifier` helper for CSI/SS3 format sequences
  - Swipe gesture buttons via `SwipeArrowButton` view
  - Updated `KeyboardToolbarContent` with generalized modifier highlighting
- [x] Update `GhosttyTerminalView.swift` call site rename
- [x] Redesign `ToolbarEditView` with two-zone layout
  - Top zone: horizontal ScrollView with x-badge chips, drag-to-reorder
  - Bottom zone: pill-shaped category tabs, LazyVGrid palette, dimmed already-added buttons
  - Reset to defaults with confirmation alert
- [x] Build on simulator — no compilation errors
