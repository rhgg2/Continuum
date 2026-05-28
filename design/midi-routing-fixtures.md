=== midi-routing capture spike ===
Track : ctm_routing_spike
FX    : VST3:ReaEQ (Cockos) or VST:ReaEQ
Phases: 9 total

=== Next: phase 1/9 — default ===
Set the FX MIDI I/O dialog to:
  input enabled, output enabled, in_bus=1, out_bus=1, REPLACE
Then hit the hotkey to capture.

=== Captured phase 1/9 — default ===
  desc              : input enabled, output enabled, in_bus=1, out_bus=1, REPLACE
  header line       : <VST "VST: ReaEQ (Cockos)" reaeq.vst.dylib 0 "" 1919247729<56535472656571726561657100000000> ""
  base64 lines      : 3
  first line bytes  : 60
  first line tail-6 : 00 00 00 00 10 00
  trailer line bytes: 6
  trailer (last 6)  : 00 00 10 00 00 00

=== Next: phase 2/9 — merge ===
Set the FX MIDI I/O dialog to:
  input enabled, output enabled, in_bus=1, out_bus=1, MERGE
Then hit the hotkey to capture.

=== Captured phase 2/9 — merge ===
  desc              : input enabled, output enabled, in_bus=1, out_bus=1, MERGE
  header line       : <VST "VST: ReaEQ (Cockos)" reaeq.vst.dylib 0 "" 1919247729<56535472656571726561657100000000> ""
  base64 lines      : 3
  first line bytes  : 60
  first line tail-6 : 00 00 00 00 18 00
  trailer line bytes: 6
  trailer (last 6)  : 00 00 18 00 00 00

=== Next: phase 3/9 — in_bus=2 ===
Set the FX MIDI I/O dialog to:
  in_bus=2, out_bus=1, REPLACE
Then hit the hotkey to capture.

=== Captured phase 3/9 — in_bus=2 ===
  desc              : in_bus=2, out_bus=1, REPLACE
  header line       : <VST "VST: ReaEQ (Cockos)" reaeq.vst.dylib 0 "" 1919247729<56535472656571726561657100000000> ""
  base64 lines      : 3
  first line bytes  : 60
  first line tail-6 : 00 00 00 00 10 00
  trailer line bytes: 6
  trailer (last 6)  : 00 00 10 01 00 00

=== Next: phase 4/9 — out_bus=2 ===
Set the FX MIDI I/O dialog to:
  in_bus=1, out_bus=2, REPLACE
Then hit the hotkey to capture.

=== Captured phase 4/9 — out_bus=2 ===
  desc              : in_bus=1, out_bus=2, REPLACE
  header line       : <VST "VST: ReaEQ (Cockos)" reaeq.vst.dylib 0 "" 1919247729<56535472656571726561657100000000> ""
  base64 lines      : 3
  first line bytes  : 60
  first line tail-6 : 00 00 00 00 10 00
  trailer line bytes: 6
  trailer (last 6)  : 00 00 10 00 01 00

=== Next: phase 5/9 — in_disabled ===
Set the FX MIDI I/O dialog to:
  INPUT DISABLED, out_bus=1, REPLACE
Then hit the hotkey to capture.

=== Captured phase 5/9 — in_disabled ===
  desc              : INPUT DISABLED, out_bus=1, REPLACE
  header line       : <VST "VST: ReaEQ (Cockos)" reaeq.vst.dylib 0 "" 1919247729<56535472656571726561657100000000> ""
  base64 lines      : 3
  first line bytes  : 60
  first line tail-6 : 00 00 00 00 51 00
  trailer line bytes: 6
  trailer (last 6)  : 00 00 51 00 00 00

=== Next: phase 6/9 — out_disabled ===
Set the FX MIDI I/O dialog to:
  in_bus=1, OUTPUT DISABLED, REPLACE
Then hit the hotkey to capture.

=== Captured phase 6/9 — out_disabled ===
  desc              : in_bus=1, OUTPUT DISABLED, REPLACE
  header line       : <VST "VST: ReaEQ (Cockos)" reaeq.vst.dylib 0 "" 1919247729<56535472656571726561657100000000> ""
  base64 lines      : 3
  first line bytes  : 60
  first line tail-6 : 00 00 00 00 52 00
  trailer line bytes: 6
  trailer (last 6)  : 00 00 52 00 00 00

=== Next: phase 7/9 — both_disabled ===
Set the FX MIDI I/O dialog to:
  INPUT DISABLED, OUTPUT DISABLED
Then hit the hotkey to capture.

=== Captured phase 7/9 — both_disabled ===
  desc              : INPUT DISABLED, OUTPUT DISABLED
  header line       : <VST "VST: ReaEQ (Cockos)" reaeq.vst.dylib 0 "" 1919247729<56535472656571726561657100000000> ""
  base64 lines      : 3
  first line bytes  : 60
  first line tail-6 : 00 00 00 00 53 00
  trailer line bytes: 6
  trailer (last 6)  : 00 00 53 00 00 00

=== Next: phase 8/9 — in_bus=128 ===
Set the FX MIDI I/O dialog to:
  in_bus=128, out_bus=128, REPLACE (boundary)
Then hit the hotkey to capture.

=== Captured phase 8/9 — in_bus=128 ===
  desc              : in_bus=128, out_bus=128, REPLACE (boundary)
  header line       : <VST "VST: ReaEQ (Cockos)" reaeq.vst.dylib 0 "" 1919247729<56535472656571726561657100000000> ""
  base64 lines      : 3
  first line bytes  : 60
  first line tail-6 : 00 00 00 00 50 00
  trailer line bytes: 6
  trailer (last 6)  : 00 00 50 7F 7F 00

=== Next: phase 9/9 — in_disabled+out_bus=1+replace ===
Set the FX MIDI I/O dialog to:
  INPUT DISABLED, out_bus=1, REPLACE (doc says n+1 = 0x80 here)
Then hit the hotkey to capture.

=== Captured phase 9/9 — in_disabled+out_bus=1+replace ===
  desc              : INPUT DISABLED, out_bus=1, REPLACE (doc says n+1 = 0x80 here)
  header line       : <VST "VST: ReaEQ (Cockos)" reaeq.vst.dylib 0 "" 1919247729<56535472656571726561657100000000> ""
  base64 lines      : 3
  first line bytes  : 60
  first line tail-6 : 00 00 00 00 51 00
  trailer line bytes: 6
  trailer (last 6)  : 00 00 51 00 00 00

=== DONE ===
All 9 configs captured.
Paste the output above into design/midi-routing-fixtures.md.
Run again to clear state.
