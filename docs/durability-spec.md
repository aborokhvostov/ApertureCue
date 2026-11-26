# Stage 3 document and media durability

This contract belongs to the independently authored ApertureCue format. It does
not describe or modify MadMapper files. MappingCore uses Foundation only. The
normal document limit remains 16 MiB; the recovery envelope has a separate 24 MiB
encoded limit because its bounded document payload is base64 encoded.

## Bound recovery

The editor uses `ProjectStore.loadWithRecoveryBaseline(from:)` for Open and
`saveWithRecoveryBaseline(_:to:)` for manual Save, and keeps the returned immutable
value until the next successful manual Save/Open. Open decodes the same bytes
used to produce its token; Save checks that the captured token matches the bytes
it just wrote. `captureRecoveryBaseline(for:)` is also available for a known
saved revision. The token records the canonical source path,
SHA-256, byte count and modification time. A matching timestamp alone never
establishes freshness: same-size, equal-mtime replacement with different bytes
invalidates recovery. Fingerprints use an original portable implementation of
SHA-256, checked against known empty/`abc`/multi-block vectors; the algorithm is
specified in [NIST FIPS 180-4](https://csrc.nist.gov/files/pubs/fips/180-4/final/docs/fips180-4.pdf).
The digest detects revision changes; it is not authentication of hostile files.

`saveRecovery(project,for:baseline:)` atomically writes a versioned envelope to
`.filename.recovery`. It serializes the portable project relative to the saved
project directory, not relative to a new working directory. The envelope binds
the payload to the saved revision and records a payload digest. Passing the
original baseline matters: recapturing the token during every autosave could
mistake an external Save for the revision used by an editor's old unsaved state.

`recoveryStatus(for:)` classifies `.missing`, `.available`, `.stale`, `.invalid`
and `.legacy`. Only `.available` can be offered for automatic Restore.
`loadRecovery` rechecks the binding and payload after the status read, decodes
and validates the project, and never writes the saved document. A copied
sidecar cannot attach to another document path even if the saved bytes match.
Plain legacy sidecars lack a revision binding and are preserved without being
automatically restored. Corrupt, unsupported and symlink sidecars are also
preserved. Autosave refuses to replace those files or another editor revision's
currently available recovery. A snapshot written with a stale explicitly held
baseline stays bound to that old revision and is not offered as current.

After successful manual Save, the editor may call
`removeRecovery(for:baseline:)` with its **pre-Save** token, then capture the new
baseline. Removal requires that exact source path, revision and valid envelope;
unrelated/corrupt/legacy sidecars are not removed. This is an ownership check,
not unconditional cleanup by filename. Undo/Redo and selection do not recapture
the saved-revision token.

Core checks use separate generated documents and cover freshness, copied paths,
legacy/corrupt/checksum/future envelopes, wrong-owner cleanup, repeated autosave
and external Save before autosave. A separate process integration check must
write a known unsaved snapshot, announce completion of the atomic write, suffer
forced termination, and load both the untouched saved document and the matching
snapshot in a new process. A cooperative exit alone does not establish crash
recovery. Neither that process check nor atomic rename establishes durability
under power loss, filesystem corruption or simultaneous adversarial writers.

## Portable folder sequences

Schema 13 stores an image sequence as a directory and a frozen ordered manifest
of safe frame basenames plus FPS. Collection copies those exact names into a
UUID-specific media directory; it never recursively copies a folder. Files added
after the manifest was captured are excluded. Numeric filename gaps remain
consecutive entries and retain their exact names and order. Playback modes,
trim/rate, source UUIDs, surface references and audio routing definitions survive
Save/Recovery/Collect.

Every declared sequence frame must be a regular file, at most 256 MiB. Leaf
symlinks are rejected so a frame cannot silently escape its selected source
folder. An explicitly selected folder alias is resolved once. Ordinary image,
video and audio file aliases retain the established behavior: resolve the source
and copy an ordinary file. Live camera identities remain identities and are not
recorded media. The total declared byte budget for one collection is 64 GiB.

Copies compare source size, modification time and file identity before/after
copying, and check the destination's regular-file type and size. These checks
reject ordinary detected mutation; they are not filesystem snapshots or content
locks. A concurrent writer that changes content while preserving metadata is
outside that guarantee. Files are not promised to retain imported bytes forever;
the folder manifest freezes names and timing, not a historical content archive.

The complete copy is validated in a randomly named sibling staging directory.
Only a same-filesystem move into a previously absent destination publishes it.
Missing/unsafe/oversized frames, failed copy, invalid serialization or destination
collision abort collection and remove only that invocation's staging directory.
The saved project, source media and any existing destination stay untouched.
Core tests verify missing/symlink/size-budget rejection and rollback, exact frozen
manifest copying, ignored additions and reopening after original-folder removal.

## Evidence boundaries

Core standalone assertions and actual XCTest CI are distinct runs. Native codec,
visible GUI, forced-process termination and hardware checks must be recorded in
the stage report separately. No physical disk-failure, camera, external audio or
long-show reliability claim follows from these portable filesystem checks.
