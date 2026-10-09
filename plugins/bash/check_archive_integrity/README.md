# check_archive_integrity

Verifies that the newest archive matching a glob **decompresses cleanly** and
that its **checksum sidecar is present**.

A freshness check proves a file appeared. This proves it is a file worth having.
Pair it with [check_file_age](../check_file_age) — neither replaces the other,
and this one will happily pass on a three-year-old archive, which is why the age
of the file it tested appears in both the output and the performance data.

## Requirements
- Icinga 2 >= 2.13.0
- Bash >= 4.x
- GNU `find` (uses `-printf`) and `timeout`
- The decompressor for the archive type in use: `gzip`, `bzip2`, `xz`, `tar`,
  or `unzip`
- Read access to the archives. Backups are commonly mode `600` in a mode `700`
  directory — see [INSTALL.md](INSTALL.md).

## Compatibility
See Compatibility Matrix below.

## Usage
```
check_archive_integrity -p <directory> --pattern <glob> [--sidecar-ext <ext>]
                        [--min-age-seconds <n>] [-t <seconds>] [-V] [-h]
```

## Arguments

| Argument            | Required | Default   | Description                                                      |
|---------------------|----------|-----------|------------------------------------------------------------------|
| -p / --path         | Yes      |           | Directory to look in (not recursive)                             |
| --pattern           | Yes      |           | Filename glob, e.g. `itop-db-*.sql.gz`. Must not contain `/`     |
| --sidecar-ext       | No       | `.sha256` | Sidecar suffix appended to the archive name; `''` skips the check |
| --min-age-seconds   | No       | 300       | Never test an archive younger than this                          |
| -t / --timeout      | No       | 300       | Timeout for the decompression test                               |
| -V / --version      | No       |           | Show plugin version                                              |
| -h / --help         | No       |           | Show help                                                        |

## Behaviour

| Condition                                                   | State    |
|-------------------------------------------------------------|----------|
| Archive decompresses and the sidecar is present             | OK       |
| Every match is younger than `--min-age-seconds`             | OK (nothing tested, stated in the output) |
| Sidecar missing or empty                                    | WARNING  |
| **Archive fails the decompression test**                    | CRITICAL |
| No file matches the pattern                                 | CRITICAL |
| Directory does not exist                                    | CRITICAL |
| Archive is unreadable, or its type has no known test        | UNKNOWN  |
| Decompression test timed out                                | UNKNOWN  |
| Missing required argument                                   | UNKNOWN  |

CRITICAL outranks WARNING, which outranks UNKNOWN — so "cannot read the sidecar"
can never mask "the archive is corrupt". (This is deliberately *not* the repo's
usual severity ladder, which ranks UNKNOWN highest.)

## Why the two findings are not the same severity

They test different things:

- **Decompression failure is CRITICAL.** The bytes are bad; the backup cannot be
  restored.
- **A missing sidecar is WARNING.** The archive itself may be perfectly good —
  what this says is that the job did not reach its final step. That is a script
  regression, not a missing backup, and calling it CRITICAL over-weights it.

## Why `--min-age-seconds`

Running `gzip -t` against a file that is still being written fails reliably with
"unexpected end of file" — a false CRITICAL every time the check and the backup
job overlap. Scheduling the check outside the backup window is mitigation by
convention, and the window drifts as the dump grows.

Instead, this check only ever reads an archive that has been untouched for at
least `--min-age-seconds`. If the newest match is younger than that, the
previous one is tested and the output says so; if *everything* is that fresh,
the check reports OK and states plainly that nothing was verified.

## Note on `--sidecar-ext` and checksums

The sidecar is checked for **presence**, not recomputed. `gzip -t` already
verifies the CRC32 of the decompressed stream, which is a stronger corruption
test than re-hashing the compressed bytes; the sidecar's value is provenance
(this is the file the job claims it wrote), and recomputing it would mean
reading a large dump a second time for little gain.

## Example Output

```
check_archive_integrity OK - tested itop-db-2026-09-25_2330.sql.gz (7200s old): integrity=OK sidecar=OK | archive_bytes=418234901B tested_age_seconds=7200s integrity_ok=1 sidecar_present=1
[OK] itop-db-2026-09-25_2330.sql.gz decompresses cleanly (418234901 bytes, 7200s old)
[OK] itop-db-2026-09-25_2330.sql.gz.sha256 present

check_archive_integrity CRITICAL - tested itop-db-2026-09-25_2330.sql.gz (7200s old): integrity=CRIT sidecar=OK | archive_bytes=193B tested_age_seconds=7200s integrity_ok=0 sidecar_present=1
[CRIT] itop-db-2026-09-25_2330.sql.gz failed the decompression test: gzip: unexpected end of file
```

## Performance Data

| Label                | UOM | Description                                             |
|----------------------|-----|---------------------------------------------------------|
| `archive_bytes`      | B   | Size of the archive tested                              |
| `tested_age_seconds` | s   | Age of the archive tested — *not* of the newest archive |
| `integrity_ok`       |     | 1 pass, 0 fail, `U` not tested                          |
| `sidecar_present`    |     | 1 present, 0 missing/empty, `U` check disabled          |

## Known Limitations
- Not recursive (`-maxdepth 1`), and requires GNU `find`.
- Tests only the newest eligible archive, not the whole retention set.
- `gzip -t` on a `.tar.gz` would validate only the gzip layer, so `.tar.gz` and
  `.tgz` are tested with `tar -tzf` instead.
- A passing result says nothing about the archive's age — read it alongside
  `check_file_age`.

## Compatibility Matrix

| Plugin Version | Icinga 2 Version | OS                     | Lang Version |
|----------------|------------------|------------------------|--------------|
| 1.0.0          | >= 2.13.0        | RHEL / Rocky / AlmaLinux 8/9 | Bash 4.x |
| 1.0.0          | >= 2.13.0        | Ubuntu 22.04/24.04     | Bash 5.x     |
| 1.0.0          | >= 2.13.0        | Debian 11/12           | Bash 5.x     |

## License
MIT — see [LICENSE](../../../LICENSE)
