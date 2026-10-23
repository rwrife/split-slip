# Issue #14 — two-surface architecture evidence

## Implemented

- `ReceiptWorkspaceLayout` explicitly models semantic surfaces (`receiptReference`,
  `peopleAllocations`) and presentations (`compactTabs`, `dualSurface`).
- `ReceiptEditorView` composes either compact tabs or side-by-side surfaces over
  a single `ReceiptWorkspaceModel`. Layout owns no receipt, participant, line,
  selection, or viewport state.
- Production defaults to `.compact`. No screen-width heuristic, device-name
  sniffing, hinge estimation, iPad enablement, or private API exists.
- Simulator UI tests can supply `-ui-testing-dual-surface` to compile and
  exercise both surfaces simultaneously, prove shared selection across them,
  and verify that state survives switching back to compact mode on relaunch.
- Enforced iPhone-only policy: `TARGETED_DEVICE_FAMILY = 1` remains unchanged.

## Evidence boundaries

Unit and domain test suites prove that `ReceiptWorkspaceLayout` models
presentation and surfaces without holding domain state. Pinned iPhone simulator
UI tests prove that both SwiftUI surfaces render together, accept interaction,
and retain selection across orientation and relaunch.

Neither test proves compatibility with unreleased hardware, physical dual
displays, a hinge, or future Apple SDK APIs. Issue #14 remains open until a
public platform API and physical device evidence are available to verify the
production adapter. No Duo hardware or SDK compatibility is claimed.
