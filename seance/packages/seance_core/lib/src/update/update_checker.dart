import 'dart:convert';

import 'package:http/http.dart' as http;

import 'version.dart';

/// The shared release repository for all Hauntware applications.
const hauntwareUpdateRepo = 'L-K-M/Hauntware';

/// A file attached to a release, with the SHA-256 digest GitHub computed
/// when it was uploaded.
class ReleaseAsset {
  /// The file name, e.g. `seance-android.apk`.
  final String name;

  final Uri downloadUrl;

  /// The size in bytes.
  final int size;

  /// The SHA-256 digest as lower-case hex.
  final String sha256;

  const ReleaseAsset({
    required this.name,
    required this.downloadUrl,
    required this.size,
    required this.sha256,
  });

  /// GitHub's `digest` field, e.g. `sha256:0be7…` (64 hex digits).
  static final _digest = RegExp(r'^sha256:([0-9a-fA-F]{64})$');

  /// Parses one entry of a release's `assets` list, or null when any field
  /// is missing or malformed. An asset without a digest is never offered:
  /// nothing unverifiable gets downloaded.
  static ReleaseAsset? tryParse(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final name = json['name'];
    final url = json['browser_download_url'];
    final size = json['size'];
    final digest = json['digest'];
    if (name is! String || name.isEmpty) return null;
    if (url is! String || size is! int || size <= 0 || digest is! String) {
      return null;
    }

    final downloadUrl = Uri.tryParse(url);
    if (downloadUrl == null || downloadUrl.scheme != 'https') return null;
    final match = _digest.firstMatch(digest);
    if (match == null) return null;

    return ReleaseAsset(
      name: name,
      downloadUrl: downloadUrl,
      size: size,
      sha256: match.group(1)!.toLowerCase(),
    );
  }
}

/// The result of an update check.
class UpdateInfo {
  /// The latest published version tag (e.g. `0.3.0`), normalized (no leading
  /// `v`).
  final String latestVersion;

  /// The human-facing page to send the user to. The check itself never
  /// downloads anything; only an Android app fetches its APK from [assets],
  /// and only once the user chooses to update.
  final Uri releasesUrl;

  /// The release's verifiable files by name; see [ReleaseAsset.tryParse].
  final Map<String, ReleaseAsset> assets;

  const UpdateInfo({
    required this.latestVersion,
    required this.releasesUrl,
    this.assets = const {},
  });
}

/// Checks GitHub for a newer suite release than the one running.
///
/// This is read-only and best-effort: it only ever *reports* that a newer
/// version exists, with the releases page and the release's files. It never
/// fetches or installs anything. On any error (offline, rate-limited, malformed
/// response) it returns null so the caller can silently carry on.
class UpdateChecker {
  final http.Client _client;
  final Duration timeout;

  /// `owner/repo` whose releases are checked.
  final String repo;

  UpdateChecker({
    this.repo = hauntwareUpdateRepo,
    http.Client? client,
    this.timeout = const Duration(seconds: 15),
  }) : _client = client ?? http.Client();

  Uri get _latestReleaseApi =>
      Uri.parse('https://api.github.com/repos/$repo/releases/latest');

  /// The public releases page (where the check sends the user).
  Uri get releasesPage =>
      Uri.parse('https://github.com/$repo/releases/latest');

  /// Returns [UpdateInfo] when GitHub's latest release is strictly newer than
  /// [currentVersion]; null when up to date, when the check can't be completed,
  /// or when either version is unparseable.
  Future<UpdateInfo?> check(String currentVersion) async {
    try {
      final res = await _client.get(
        _latestReleaseApi,
        headers: const {
          'Accept': 'application/vnd.github+json',
          // GitHub requires a User-Agent or it returns 403.
          'User-Agent': 'Seance-update-check',
        },
      ).timeout(timeout);

      // GitHub answers 404 when a repo has no published (non-draft) release,
      // and 403 when rate-limited; both mean "nothing to report".
      if (res.statusCode != 200) return null;

      final body = jsonDecode(res.body);
      if (body is! Map<String, dynamic>) return null;
      final tag = body['tag_name'];
      // Skip drafts/prereleases — only stable releases should nag.
      if (body['draft'] == true || body['prerelease'] == true) return null;
      if (tag is! String) return null;

      if (!AppVersion.isNewer(current: currentVersion, candidate: tag)) {
        return null;
      }
      final parsed = AppVersion.tryParse(tag);
      return UpdateInfo(
        latestVersion: parsed?.toString() ?? tag,
        releasesUrl: releasesPage,
        assets: _assets(body['assets']),
      );
    } catch (_) {
      // Offline / timeout / malformed JSON — never surface as an error.
      return null;
    }
  }

  /// The well-formed entries of a release's `assets` list; a malformed one
  /// is left out rather than failing the check.
  static Map<String, ReleaseAsset> _assets(Object? json) {
    if (json is! List) return const {};
    return Map.unmodifiable({
      for (final entry in json)
        if (ReleaseAsset.tryParse(entry) case final asset?) asset.name: asset,
    });
  }
}
