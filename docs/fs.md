# fs

Pure filesystem helpers. The single layer that talks to
`reaper.Enumerate*` and the IO API; UI/view code routes through here.

## Content fingerprint

`fs.hashFile` returns an 8-char hex digest computed from the file's
size and its first/last 4 KB only. A 30 MB sample hashes in
microseconds, where reading the whole file would block the render loop.

Two distinct audio files that collide in size *and* both endpoints is
vanishingly unlikely under normal use, so the digest is good enough
for "is this the same file?" dedup against the slot store. It is
**not** a cryptographic hash — do not use it as one.

The hash is FNV-1a over `<size>\0 <head> <tail>`, masked to 32 bits.

## Sort order

`listDirs` / `listAudioFiles` sort case-insensitively so the browser
matches user expectations from Finder/Explorer. Dotfile-prefixed
entries (`.git`, `.DS_Store`, …) are hidden from `listDirs`.

## Path joining

`fs.join` is concatenative — no normalisation, no `..` resolution. It
inserts `'/'` between components unless the left side already ends in
a separator. Callers pass canonical paths.
