# Release versions

This library holds the release-version arithmetic. The suite tool at the
repository root, [`tool/release_version`](../../../tool/release_version),
re-exports it and owns the tree checks, metadata rewrites and CLI that
`scripts/release.sh` and CI run.

Accepted versions are `X.Y.Z`. Components are canonical decimal; minor and
patch are `0..99`. Suffixed releases are unsupported; stable-only is the
selected [milestone §3.12](../../docs/plan/07-MILESTONES.md) rule.

Android uses:

```text
major * 1,000,000 + minor * 10,000 + patch * 100 + 99
```

The result cannot exceed `2,100,000,000`.

Only app pubspecs receive Flutter's `+versionCode`. Apple bundle versions
use `(major + 1).minor.patch`, preserving order while keeping the first
component positive. Windows numeric resources use the semantic components.
