# Live integration fixture

`run.sh` owns the Docker/SSH/sync services, readiness, serialized suites,
and teardown. The sync convergence suite also runs against a separately
started real sync server through `KLABAUTERMANN_SYNC_SERVER`.

`previous_release.sh WORK_DIR` archives the latest release's four required
packages and compiles the live client harness against their public APIs.
`previous_release.sh --current WORK_DIR` archives the same bounded package
set from HEAD. The two builds resolve dependencies sequentially. Their
executables are exported as `KLABAUTERMANN_PREVIOUS_RELEASE_HARNESS` and
`KLABAUTERMANN_CURRENT_HARNESS`.

The harness reports its compiled wire protocol with `--protocol-version`.
With account options it runs `--client seance`, `--client poltergeist`, or
both clients when the selector is omitted. Successful output names only
the records that client pushed; a server API refusal produces a structured
error on stderr and no successful record output.

The suite exercises previous clients independently. A compatible protocol
must complete the original opaque-record roundtrip. An incompatible
protocol must receive `protocol_version` and leave the complete record set,
sequence numbers, encrypted blobs, deletion flags, envelope floor,
registration metadata and current sessions unchanged. Original current
Séance and Klabautermann sessions must still run afterwards. Current
Séance, Poltergeist and the default combined harness must always complete
the successful roundtrip, preserving opaque Klabautermann records. This
keeps the old-client rejection check from replacing interoperability
coverage during an intentional wire-protocol cutover.
