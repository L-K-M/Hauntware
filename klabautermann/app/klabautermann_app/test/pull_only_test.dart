import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/fake_ssh_config.dart';
import 'support/harness.dart';

/// Whether [request] could push catalog records or write server-side
/// state. Pull-only from the start (03 D14): the catalog applies pulled
/// records and never seals dirty ones, so no UI path may send these.
bool _pushesOrWrites(EngineRequest request) => switch (request) {
  // Enrollment and sync rounds write catalog state; a round can seal and
  // push once the engine's push policy opens (D14 keeps it closed).
  EnrollSync() || RunSyncRound() => true,
  // The action path mutates a host and its operation records.
  PlanAction() || RunAction() => true,
  // Alert acknowledgement and dismissal write `klabautermann:alertstatus`
  // catalog records (v1.x, D42).
  HandleAlert() => true,
  _ => false,
};

void main() {
  testWidgets('no surface sends a request that pushes or writes server '
      'records', (tester) async {
    final harness = await pumpApp(
      tester,
      size: const Size(1280, 800),
      servers: twoServers,
      sshConfig: FakeSshConfigSource.text('Host web-2\n'),
    );

    // Exercise every control the scaffold ships: select a server, collapse
    // the section, import ~/.ssh/config (FL-02), open the settings route
    // and switch the theme, run a sampler subscription the way the
    // monitor set will drive it (03 §10.1), then answer the engine's
    // prompts. The traffic this produces is the traffic to judge.
    await tester.tap(find.text('web-1'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Hide section'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Add'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import from ~/.ssh/config'));
    await tester.pumpAndSettle();
    expect(harness.engine.sentOfType<ImportSshConfig>(), hasLength(1));
    harness.engine.emit(
      const SshConfigImported(importedCount: 1, skippedCount: 0, saved: true),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Appearance'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();
    harness.monitoring.subscribe('srv-1', 'row', const {SampleStream.overview});
    harness.monitoring.unsubscribe('srv-1', 'row');
    await tester.pumpAndSettle();
    harness.engine.emit(
      const Prompt(
        promptId: 'p-1',
        serverId: 'srv-1',
        host: 'web-1.example',
        port: kSshDefaultPort,
        request: HostKeyPromptRequest(
          keyType: 'ssh-ed25519',
          fingerprintSha256: 'SHA256:abc',
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Trust and connect'));
    await tester.pumpAndSettle();
    harness.engine.emit(
      const Prompt(
        promptId: 'p-2',
        serverId: 'srv-1',
        host: 'web-1.example',
        port: kSshDefaultPort,
        request: KeyboardInteractivePromptRequest(questions: ['Code:']),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(harness.engine.sentOfType<AnswerPrompt>(), hasLength(2));

    // Prove the drive reached the engine, then judge every request.
    expect(harness.engine.sent, isNotEmpty);
    for (final request in harness.engine.sent) {
      expect(
        _pushesOrWrites(request),
        isFalse,
        reason:
            'the app sent $request, which can push or write records '
            '(D14 pull-only)',
      );
    }
  });
}
