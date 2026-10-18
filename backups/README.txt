Saved native captures and local build files
=========================================

local-artifacts-2026-10-18.tar.gz preserves the 154 files from artifacts/,
11 files from .build/, and four Python bytecode cache files from __pycache__/
that were present on October 18, 2026. The archive includes live app exports,
generated reports, validation evidence, synthetic Swift harnesses, executables,
and codec probe sources. It contains 169 files and about 1.85 GB before
compression. Original files remain in their local working directories.
One likely API credential was redacted from eight occurrences across six
capture/report files in this published archive. The local originals were not
modified. All other archived file bytes match the local originals.

This is private captured app data. It can include document text and window
contents. Keep the repository private and review captures before sharing them.
Build files reflect the local machine and toolchain at capture time; the
source launcher can rebuild the engine when needed.

The JSON manifest records each path, byte size, mode, and published SHA-256,
as well as the archive's checksum. For redacted files it also records the
original local SHA-256 and the number of replacements. Every archived file
was read back and verified against the published checksums before upload.
Native capture fingerprints still describe the original unredacted exports;
they were not recomputed after redaction. Use the manifest's published file
checksums to verify the archive. Compression retains the original paths while
avoiding GitHub's per-file limit on the two large raw snapshot files.

Verify the archive from the repository root:

  python3 -c 'import hashlib,json,pathlib; p=pathlib.Path("backups/local-artifacts-2026-10-18.tar.gz"); m=json.loads(p.with_name("local-artifacts-2026-10-18.manifest.json").read_text()); assert hashlib.sha256(p.read_bytes()).hexdigest()==m["archive_sha256"]; print("Archive checksum verified")'

Restore into a separate directory from the repository root:

  mkdir -p restored-local-artifacts
  tar -xzf backups/local-artifacts-2026-10-18.tar.gz -C restored-local-artifacts

The result has artifacts/, .build/, and __pycache__/ beneath that directory.
For example, saved reports can be opened from restored-local-artifacts/artifacts/.
The restore directory is ignored by Git. No native app capture or action is
needed to inspect these saved exports.
