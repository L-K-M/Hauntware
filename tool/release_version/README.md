# Release versions

Accepted versions are `X.Y.Z`, `X.Y.Z-beta1..49`, and
`X.Y.Z-rc1..49`. Components are canonical decimal; minor and patch are
`0..99`.

Android uses:

```text
major * 1,000,000 + minor * 10,000 + patch * 100 + stage

betaN: N       rcN: 49 + N       final: 99
```

The result cannot exceed `2,100,000,000`.

```bash
dart run tool/release_version/bin/release_version.dart validate --version 1.2.3
dart run tool/release_version/bin/release_version.dart check
dart run tool/release_version/bin/release_version.dart check-tag --tag v1.2.3
```

`scripts/release.sh` invokes `sync` after the shared release tool updates
semantic versions. Only the app pubspec receives Flutter's `+versionCode`.
