// The suite link contract corpus (docs/design/suite-links.md section 9)
// through Poltergeist's intake: no refused row reaches a handler.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/deep_links.dart';

const _corpusPath =
    '../../../seance/packages/seance_core/test/fixtures/suite_link_corpus.json';

void main() {
  final json =
      jsonDecode(File(_corpusPath).readAsStringSync()) as Map<String, Object?>;
  final rows = [
    for (final row in json['rows']! as List<Object?>)
      row! as Map<String, Object?>,
  ];

  for (final row in rows) {
    final uri = row['uri']! as String;
    final form = row['form']! as String;
    final accepted =
        row['verdict'] == 'accept' && form.startsWith('poltergeist:');
    test(
      '${accepted ? 'opens' : 'refuses'} $form: ${row['note'] ?? uri}',
      () async {
        final handler = _Handler();
        final coordinator = DeepLinkCoordinator()..activate(handler);

        coordinator.add(Uri.parse(uri));
        await coordinator.idle;

        if (!accepted) {
          expect(handler.reviews, 0);
          expect(handler.hosts, isEmpty);
          expect(handler.servers, isEmpty);
          final kind = form.startsWith('poltergeist:')
              ? row['kind']
              : DeepLinkFailureKind.unsupportedLink.name;
          expect(handler.failures.map((failure) => failure.kind.name), [kind]);
          return;
        }

        expect(handler.failures, isEmpty);
        if (form == 'poltergeist:id') {
          expect(handler.servers, hasLength(1));
        } else {
          expect(handler.reviews, 1);
          expect(handler.hosts, hasLength(1));
        }
      },
    );
  }
}

final class _Handler implements DeepLinkHandler {
  var reviews = 0;
  final hosts = <HostDeepLink>[];
  final servers = <ServerDeepLink>[];
  final failures = <DeepLinkFailure>[];

  @override
  Future<DeepLinkReviewDecision> reviewHost(DeepLinkReview review) async {
    reviews++;
    return DeepLinkReviewDecision.connect;
  }

  @override
  Future<DeepLinkHostResult> openHost(
    HostDeepLink link,
    DeepLinkOperation operation,
  ) async {
    hosts.add(link);
    return DeepLinkHostResult.committed;
  }

  @override
  Future<DeepLinkServerResult> openServer(
    ServerDeepLink link,
    DeepLinkOperation operation,
  ) async {
    servers.add(link);
    return DeepLinkServerResult.opened;
  }

  @override
  Future<void> showFailure(
    DeepLinkFailure failure,
    DeepLinkOperation operation,
  ) async {
    failures.add(failure);
  }
}
