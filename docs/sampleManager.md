# sampleManager

Wire-protocol bridge between the configManager (the authority for slot
state) and the Continuum Sampler JSFX (a pure consumer of decoded
audio). cm holds the canonical slot table; sm publishes it across the
gmem boundary, watches for resets on the JSFX side, and re-publishes
when state was lost.

## Authority

cm is the sole source of truth for `{path, start, end, name}` per
slot. The JSFX renders sound; it does not persist what it should be
playing. Every observable change to slot state — `assign`, `setTrim`,
`setName`, `clearSlot`, `loadSlot` — first writes cm and then queues a
mailbox push. The reverse direction does not exist: there is no path
by which the JSFX can mutate cm.

That asymmetry makes recovery uniform. After any JSFX reset (project
reload, recompile, FX delete-and-recreate, paused-then-resumed audio
thread), sm walks cm and re-publishes. The reset is detected, not
guessed; see *Boot-token rehydrate* below.

## Storage model

Slot data lives in `cm:get('slotEntries')` at the **track tier**,
persisted via `P_EXT:ctm_config`. Shape:

```
slotEntries = {
  [idx] = { path = 'Continuum/<base>-<rand8>.<ext>',
            name = string?, start = number?, ['end'] = number? },
  ...
}
```

`idx` is 0-indexed to match MIDI PC values and the JSFX slot index.
`path` is **always project-relative** in cm. `reaper.GetProjectPath(0)`
transparently returns REAPER's default media folder for unsaved
projects and the project's own media folder once saved, so keeping cm
relative means the on-save migration moves bytes; cm contents are
unchanged. Unknown fields persist round-trip — cm prunes only unknown
*top-level* keys.

Across the wire sm composes absolute paths from the cached project
prefix (`setPrefix`) at every push, so the JSFX itself stores no
prefix state.

## Ownership of audio bytes

`assign` copies every assigned file into `<projectMedia>/Continuum/`
under `<stem>-<rand8>.<ext>`, where the hex tail is a content
fingerprint (`fs.hashFile`). The original is never referenced after
assignment — Continuum owns the bytes, which matters for forthcoming
destructive editing. Originals are not modified.

The JSFX `@serialize` round-trips decoded audio so warm-start is fast,
but cm wins on conflict: every reset triggers a rehydrate that
re-issues the mailbox for every entry.

## Per-instance addressing

Each sampler-bearing track holds a `samplerInstanceId` in track P_EXT,
allocated lazily by `getInstanceId`. The id partitions the gmem
bundled-mailbox region so multiple Continuum Sampler instances on the
same project don't collide.

`getInstanceId` always echoes the resolved id back into JSFX slider2
(parameter index `SLIDER_INSTANCE_ID`). A drifted slider — manual
reset, fresh FX before `@serialize` runs — would otherwise silently
swallow our writes. Allocation walks every track, gathers taken ids,
and picks the lowest free one. Slot 1 is reserved by convention
(`SLIDER_INSTANCE_ID`); allocation starts at 2.

## Bundled mailbox

For each instance the sampler exposes a per-slot mailbox at gmem
offset `SLOT_BASE + id * SLOT_STRIDE`. Payload (gmem words):

```
[seq, seq_ack, slot, op, start, end, pathLen, nameLen,
 <path bytes…>, <name bytes…>]
```

- `op = 0` write fields, `op = 1` clear slot.
- `seq` is bumped by sm; the JSFX echoes the consumed value into
  `seq_ack`. The channel is **clear** when `seq == seq_ack`. sm only
  drains a new entry on a clear channel.
- `start`/`end` are sample frames; absent fields propagate as zero.
- `path` and `name` are packed back-to-back, length-bounded by their
  respective `pathLen`/`nameLen` words — there is no separator.

Pending writes coalesce per slot. The internal queue
`{ byOrder, bySlot }` preserves first-seen order while letting later
writes to the same slot overwrite the in-flight payload (last-write-
wins consolidation). At most one slot is drained per tick. With the
channel-clear gate this caps the in-flight rate to one mailbox per
JSFX block — comfortable for the JSFX consumer and simple for sm to
reason about.

The PATH_MAX of 1019 plus the 8-word header plus NAME_MAX of 64 yields
a stride of 1091 floats. The JSFX user-string slot cap is 1023, which
constrains how much of the payload can land in a string slot if a
future change moves bytes there; current writes stay in numeric gmem.

## Boot-token rehydrate

On every block the JSFX writes a one-shot non-zero token at
`BOOT_BASE + id`. After fresh `@init`, that cell is zero, the JSFX
generates a new `rand(2^30) + 1`, and sm sees the new value on its
next tick. Any change in the observed token (zero → nonzero, or any
value-to-different-value transition) means the JSFX has lost its slot
state; sm calls `rehydrateTrack(track, cm)` and queues every entry.

Triggers in practice:

- Fresh project (no `@serialize`): zero → new token.
- Recompile: `@init` re-fires, slot data lost, new token.
- Audio thread paused/resumed: token survives, no rehydrate.
- FX delete and recreate: gmem persists across delete, but the new
  instance's `@init` re-fires and emits a fresh token — token change
  triggers rehydrate. The FX GUID also changes; see below.

## GUID tracking

sm tracks `TrackFX_GetFXGUID(track, fxIdx)` per track. First sight
binds the guid without resetting state. A subsequent change — sampler
removed and replaced, or moved between tracks — resets `fxGuid`,
`lastBootToken`, `slotSeq`, and the pending queue, then lets the
boot-token path drive a fresh rehydrate on the next tick.

The first-sight branch is load-bearing: writes queued before the very
first tick must survive into the drain. Treating "no prior guid" as
"guid changed" would wipe them.

## Multi-track rehydrate

Rehydrate must work for sampler tracks that aren't the currently-
bound one — every Continuum window watches every sampler instance.
`ds:getAt(otherTrack, 'slotEntries')` reads any track's P_EXT
directly without rebinding context; `rehydrateTrack` uses it to walk
non-active tracks.

## Save migration

The project's media folder is the global REAPER media folder
pre-save and project-local post-save. When the resolved path
changes, slot files have to follow. `watchPath()` diffs the live
`GetProjectPath(0)` against `cm.lastProjectPath` (a project-tier
breadcrumb) and, on a mismatch, sets the prefix, runs `migrate`,
and writes the new path back. Because the breadcrumb lives in
project-tier cm, it serialises into the .RPP — so a save that
happens while Continuum is closed is still caught the next time
the project is opened with Continuum running.

`migrate(projectPath, oldProjectPath)` walks every sampler track via
`ds:getAt(track, 'slotEntries')` and moves each entry's bytes
from old root to new. ds `path` strings stay relative so no slot
rewrite is needed. If `oldProjectPath` is nil or equals `projectPath`, migrate
is a no-op. Migrate runs independently of rehydrate — they target
different boundaries (project-path change vs. fresh-mem detection).

## Tick lifecycle

`sm:tick(cm)` is the coordinator heartbeat, called every frame. Per
sampler-bearing track it: refreshes the instance id mirror, watches
the FX guid, watches the boot token, fires `rehydrateTrack` on a
token or guid change, and drains at most one pending entry through
the bundled mailbox.

`samplePage:tick` runs every frame regardless of active page or
take selection. It calls `sm:watchPath(cm)` — which sets the
prefix on a project-path change — before `sm:tick(cm)`, so the
first mailbox push after a fresh project load already composes
against the right `currentPrefix`. `probeMode` is the only
take-dependent piece and is skipped when no take is bound.

## Preview

Preview audition retains its legacy magic-gated mailbox at
`PREVIEW_BASE`. It is real-time, single-shot, and not part of the cm
authority pipeline; preview state is never persisted and never
rehydrated. `previewSlot(track, slot, bounds)` auditions an existing
slot (`bounds = 1` honours `start`/`end`, `bounds = 0` plays the full
file); `previewPath(track, path)` loads a file into the hidden preview
slot at index `N_SAMPLES` and auditions it without consuming a real
slot. `stopPreview(track)` stops audition.

`stageInto` and `loadSlot` swap the JSFX slot's audio without writing
cm — the **preview-in-place** seam used by `samplePage`. cm's truth
returns via `syncSlot`, which queues a mailbox push for whatever cm
holds. The pair lets the user scrub through the file browser into the
selected slot without disturbing persistent state.

## Dependency injection

`newSampleManager(fileOps)` takes one collaborator:

- `fileOps` — `{ copy(src,dst) → bool, move(src,dst) → bool, mkdir(dir) → () }`.

cm is supplied per call rather than at construction, so the same sm
can serve multiple cm contexts (e.g. multi-track rehydrate). Tests
pass call-recording stubs; production wires the real
`io.open`/`os.rename`/`reaper.RecursiveCreateDirectory`.
