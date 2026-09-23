# Enco X3 for Mac

Independent native Swift macOS application. The current agent implements, reviews, and verifies routine work directly, including small fixes and UI iteration. Use Kimi only when the user explicitly requests delegation or a genuinely independent workstream has a clear benefit; do not dispatch merely because the current agent is Astra. No GPT workers.

## Device safety
- Start with read-only enumeration and status queries on an already paired, connected OPPO Enco X3.
- Use IOBluetooth RFCOMM and resolve the vendor service UUID via SDP; never POSIX Bluetooth socket constants.
- Never pair/unpair, factory reset, update firmware, or send unknown write commands.
- Before a setting test, record its exact original value; verify replies and read back; restore and verify original value after testing.
- Distinguish observed protocol facts, upstream claims, and unverified interpretation. Unknown battery is not zero.
- Do not claim Apple proprietary ecosystem support (Find My, iCloud pairing, automatic Apple device switching, native AirPods UI).

## Implementation
- Swift Package core protocol library, native IOBluetooth transport, diagnostic CLI, SwiftUI menu bar UI.
- Keep protocol parsing deterministic and independently testable. Partial RFCOMM reads must be buffered.
- Raw local device identifiers/logs belong in ignored local evidence; commit sanitized evidence only.
- Respect source licenses and document pinned upstream references and derived code.
- Workers may not stage, commit, create branches, or delegate. Main agent reviews actual source and results.
