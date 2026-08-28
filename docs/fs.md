# fs

Directory listing, path handling, and the reading, hashing and copying
of files.

## Stance

1. fs is the only module that touches `reaper.Enumerate*` and
   filesystem IO. It holds no state and knows nothing of Continuum's
   model; UI and view code reach the disk through it.

1. `listDirs` and `listAudioFiles` sort case-insensitively, so the
   browser orders entries as Finder and Explorer do. `listDirs` hides
   dotfile entries.

1. fs performs no normalisation: `join` concatenates and `parent`
   strips a component, neither resolving `..`. Callers hold canonical
   paths.

## Content fingerprint

1. `fs.hashFile` digests a file's size together with its first and
   last 4 KB. The cost is therefore independent of file size — a 30 MB
   sample hashes in microseconds, so the render loop can take one
   during a frame.

1. sampleManager identifies a sample by its digest, so a file already
   copied into the project is recognised and not copied again
   (`docs/sampleManager.md`). Two audio files that collide in size and
   in both endpoints collide here.

1. The digest is persisted: it names the copy on disk, as
   `Continuum/<stem>-<hash>.<ext>`, and cm holds that path. Changing
   how it is computed orphans every sample already copied.

## fileOps

1. `fs.fileOps` bundles the write side — `copy`, `move`, `mkdir` —
   with `exists` and `hash`, as one table a caller takes as a
   dependency.

1. samplePage passes it to sampleManager, which reaches the disk
   through nothing else. `tests/specs/slot_store_spec.lua` passes a
   call-recording stub in its place.
