import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/preview_session.dart';
import 'package:poltergeist_app/services/quick_look_channel.dart';
import 'package:poltergeist_app/services/selection_state.dart';
import 'package:poltergeist_app/services/sync_compare_controller.dart';
import 'package:poltergeist_app/services/workspace_controller.dart';
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:poltergeist_sync/poltergeist_sync.dart';

import '../support/preview_harness.dart';

void main() {
  group('panel fallback (no Quick Look surface)', () {
    test(
      'selection alone never downloads — Space opens the prompt card',
      () async {
        final h = await PreviewHarness.create();
        await h.connectRemote([previewEntry('notes.txt', size: 4)]);

        // Focus alone ran no production and the panel stayed hidden.
        expect(h.producer.specs, isEmpty);
        expect(h.workspace.previewPanelHidden, isTrue);

        expect(h.session.previewFocused(), isTrue);
        await untilPhase(h.session, PreviewPhase.prompt);
        expect(h.workspace.previewPanelHidden, isFalse);
        expect(h.session.phase, PreviewPhase.prompt);
        expect(h.session.entry?.name, 'notes.txt');
        expect(h.producer.specs, isEmpty);
      },
    );

    test('prompt Space produces; completion renders the text file', () async {
      final h = await PreviewHarness.create();
      await h.connectRemote([previewEntry('notes.txt', size: 4)]);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.prompt);

      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.producing);
      await untilTrue(() => h.producer.specs.isNotEmpty);
      expect(h.producer.specs, hasLength(1));
      expect(h.producer.specs.single.serverId, 'srv-1');
      expect(h.producer.specs.single.remotePath, '/srv/home/notes.txt');

      await h.producer.complete(0, utf8.encode('hello\n'));
      await untilPhase(h.session, PreviewPhase.rendered);
      expect(h.session.kind, PreviewKind.text);
      expect(h.session.text, isNotNull);
      expect(h.session.file, isNotNull);
    });

    test('Space on a rendered card never hides the inspector', () async {
      final h = await PreviewHarness.create();
      await h.connectRemote([previewEntry('a.txt', size: 2)]);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.prompt);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.producing);
      await untilTrue(() => h.producer.specs.isNotEmpty);
      await h.producer.complete(0, utf8.encode('hi'));
      await untilPhase(h.session, PreviewPhase.rendered);

      h.session.previewFocused();
      await previewSettle();
      expect(h.workspace.previewPanelHidden, isFalse);
      expect(h.workspace.inspectorHidden, isFalse);
      expect(h.session.phase, PreviewPhase.rendered);
    });

    test('Space during producing is a no-op (no duplicate task)', () async {
      final h = await PreviewHarness.create();
      await h.connectRemote([previewEntry('a.txt', size: 2)]);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.prompt);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.producing);
      h.session.previewFocused();
      await previewSettle();
      expect(h.session.phase, PreviewPhase.producing);
      expect(h.producer.specs, hasLength(1));
    });

    test('compare and preview share one cache-key production', () async {
      final h = await PreviewHarness.create();
      final entry = previewEntry('notes.txt', size: 4);
      await h.connectRemote([entry]);
      final local = File('${h.tempDir.path}/local.txt')
        ..writeAsStringSync('peer');
      final comparison = SyncCompareController(
        request: SyncCompareRequest(
          relativePath: 'notes.txt',
          left: RemoteSyncCompareSource(
            side: SyncSide.left,
            fullPath: entry.path,
            snapshot: const EntrySnapshot(kind: EntryKind.file, size: 4),
            serverId: 'srv-1',
          ),
          right: LocalSyncCompareSource(
            side: SyncSide.right,
            fullPath: local.path,
            snapshot: const EntrySnapshot(kind: EntryKind.file, size: 4),
          ),
        ),
        previewCache: h.cache,
        previewProducer: h.producer,
        largeDownloadThresholdBytes: () => 4096,
      );
      addTearDown(comparison.dispose);

      final compared = comparison.start();
      await untilTrue(() => h.producer.specs.isNotEmpty);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.prompt);
      h.session.previewFocused();
      await previewSettle();
      expect(h.producer.specs, hasLength(1));

      await h.producer.complete(0, utf8.encode('same'));
      await compared;
      await untilPhase(h.session, PreviewPhase.rendered);

      expect(h.producer.specs, hasLength(1));
      expect(comparison.left.document?.text, 'same');
      expect(h.session.text?.text, 'same');
    });

    test('known over-threshold size confirms before producing', () async {
      final h = await PreviewHarness.create(thresholdBytes: 8);
      await h.connectRemote([previewEntry('big.txt', size: 100)]);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.prompt);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.confirm);
      expect(h.session.confirmBytes, 100);
      expect(h.producer.specs, isEmpty);

      // Esc answers the card's Cancel — the prompt returns.
      expect(h.session.escape(), isTrue);
      expect(h.session.phase, PreviewPhase.prompt);

      // The card's Download starts the production.
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.confirm);
      h.session.confirmDownload();
      await untilPhase(h.session, PreviewPhase.producing);
      await untilTrue(() => h.producer.specs.isNotEmpty);
      expect(h.producer.specs, hasLength(1));
      expect(h.producer.specs.single.gate, isNull);
      expect(h.producer.specs.single.maximumBytes, h.cache.capacityBytes);
    });

    test('a stale confirm cannot approve the next focused item', () async {
      final lookupStarted = Completer<void>();
      final releaseLookup = Completer<void>();
      addTearDown(() {
        if (!releaseLookup.isCompleted) releaseLookup.complete();
      });
      final h = await PreviewHarness.create(
        platform: TargetPlatform.android,
        thresholdBytes: 8,
        lookupCacheFileExists: (file) async {
          if (!lookupStarted.isCompleted) lookupStarted.complete();
          await releaseLookup.future;
          return false;
        },
      );
      final second = previewEntry('b.txt', size: 200);
      await h.connectRemote([previewEntry('a.txt', size: 100), second]);
      final secondKey = previewCacheKey('srv-1', second.path, null, 200);
      final cached = await h.cache.prepare(secondKey, extension: 'txt');
      await cached.tempFile.writeAsString('stale');
      await cached.commit();
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.prompt);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.confirm);

      h.left.setCursorIndex(1);
      await lookupStarted.future;
      final phaseAfterFocus = h.session.phase;
      h.session.confirmDownload();
      releaseLookup.complete();
      await untilPhase(h.session, PreviewPhase.prompt);

      expect(phaseAfterFocus, isNot(PreviewPhase.confirm));
      expect(h.session.entry?.name, 'b.txt');
      expect(h.producer.specs, isEmpty);
    });

    test('known under-threshold size keeps the stream safety rails', () async {
      final h = await PreviewHarness.create(thresholdBytes: 8);
      await h.connectRemote([previewEntry('small.txt', size: 4)]);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.prompt);

      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.producing);
      await untilTrue(() => h.producer.specs.isNotEmpty);
      final spec = h.producer.specs.single;
      expect(spec.expectedSize, 4);
      expect(spec.maximumBytes, h.cache.capacityBytes);
      expect(spec.gate, isNotNull);

      // The listing size is only a hint. Growth still parks at the gate.
      spec.gate!.wrap(const NullByteSink()).add(List.filled(16, 0));
      await untilPhase(h.session, PreviewPhase.gateConfirm);
    });

    test('unknown size parks at the threshold; keep-downloading resumes',
        () async {
      final h = await PreviewHarness.create(thresholdBytes: 8);
      await h.connectRemote([previewEntry('stream.txt')]);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.prompt);

      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.producing);
      await untilTrue(() => h.producer.specs.isNotEmpty);
      final spec = h.producer.specs.single;
      expect(spec.expectedSize, isNull);
      expect(spec.gate, isNotNull);
      expect(spec.maximumBytes, h.cache.capacityBytes);

      // The fake producer drives the gate's park through the spec's
      // gate object — crossing the threshold flips the card.
      spec.gate!.wrap(const NullByteSink()).add(List.filled(16, 0));
      await untilPhase(h.session, PreviewPhase.gateConfirm);

      h.session.confirmDownload();
      expect(h.session.phase, PreviewPhase.producing);
      expect(spec.gate!.isAwaitingConfirmation, isFalse);

      await h.producer.complete(0, utf8.encode('streamed bytes here'));
      await untilPhase(h.session, PreviewPhase.rendered);
    });

    test('denying the gate aborts and returns the cancelled prompt',
        () async {
      final h = await PreviewHarness.create(thresholdBytes: 8);
      await h.connectRemote([previewEntry('stream.txt')]);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.prompt);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.producing);
      await untilTrue(() => h.producer.specs.isNotEmpty);
      final spec = h.producer.specs.single;
      spec.gate!.wrap(const NullByteSink()).add(List.filled(16, 0));
      await untilPhase(h.session, PreviewPhase.gateConfirm);

      // Esc answers the gate's Cancel — the stream unwinds as cancelled.
      expect(h.session.escape(), isTrue);
      expect(spec.gate!.isDenied, isTrue);
      h.producer.fail(
        0,
        const RemoteFileException(
          kind: RemoteFileErrorKind.cancelled,
          operation: 'preview produce',
          message: 'declined',
        ),
      );
      await untilPhase(h.session, PreviewPhase.prompt);
      expect(h.session.refusal, PreviewRefusal.cancelled);
    });

    test(
      'unknown-size over-cap produce renders the refusal, not a '
      'retryable failure',
      () async {
        final h = await PreviewHarness.create();
        await h.connectRemote([previewEntry('stream.txt')]);
        h.session.previewFocused();
        await untilPhase(h.session, PreviewPhase.prompt);
        h.session.previewFocused();
        await untilPhase(h.session, PreviewPhase.producing);
        await untilTrue(() => h.producer.specs.isNotEmpty);
        // The queue re-pins the stream-cap abort to the typed limit
        // error (the produce seam's suffix-pin); the session maps it
        // to the over-cap refusal card — never failed→prompt→retry.
        h.producer.fail(
          0,
          const CheckoutLimitException('preview limit exceeded'),
        );
        await untilPhase(h.session, PreviewPhase.rendered);
        expect(h.session.refusal, PreviewRefusal.overCacheCap);
      },
    );

    test(
      'unknown-size image over the kind cap renders overKindCap',
      () async {
        final h = await PreviewHarness.create(cacheCapacityBytes: 128 << 20);
        await h.connectRemote([previewEntry('photo.png')]);
        h.session.previewFocused();
        await untilPhase(h.session, PreviewPhase.prompt);
        h.session.previewFocused();
        await untilPhase(h.session, PreviewPhase.producing);
        await untilTrue(() => h.producer.specs.isNotEmpty);
        expect(
          h.producer.specs.single.maximumBytes,
          previewKindCapBytes(PreviewKind.image),
        );
        h.producer.fail(
          0,
          const CheckoutLimitException('preview limit exceeded'),
        );
        await untilPhase(h.session, PreviewPhase.rendered);
        expect(h.session.refusal, PreviewRefusal.overKindCap);
      },
    );

    test('disposing a gated production cancels and releases it', () async {
      final h = await PreviewHarness.create(thresholdBytes: 8);
      await h.connectRemote([previewEntry('a.txt')]);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.prompt);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.producing);
      await untilTrue(() => h.producer.specs.isNotEmpty);
      final gate = h.producer.specs.single.gate!;
      gate.wrap(const NullByteSink()).add(List.filled(16, 0));
      await untilPhase(h.session, PreviewPhase.gateConfirm);

      // Session teardown must release the producer and its cache-key lock.
      h.session.dispose();
      await previewSettle();

      expect(gate.isDenied, isTrue);
      expect(h.producer.cancels, ['produce-0']);
      final next = await h.cache
          .reserveProduction(
            previewCacheKey('srv-1', '/srv/home/a.txt', null, null),
          )
          .timeout(const Duration(seconds: 1));
      expect(next, isNotNull);
      next!.release();
    });

    test('a late successful producer cannot recreate a disposed temp',
        () async {
      final producer = _LateCompletingPreviewProducer();
      final h = await PreviewHarness.create(previewProducer: producer);
      await h.connectRemote([previewEntry('a.txt', size: 2)]);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.prompt);
      h.session.previewFocused();
      await untilTrue(() => producer.specs.isNotEmpty);

      h.session.dispose();
      await previewSettle();
      await producer.complete(utf8.encode('hi'));
      await previewSettle();
      final temps = await h.tempDir
          .list()
          .where((entry) => entry.path.endsWith('.part'))
          .toList();

      expect(producer.cancels, ['late-produce']);
      expect(temps, isEmpty);
    });

    test(
      'dispose after a reservation grant skips lookup and releases',
      () async {
        final h = await PreviewHarness.create(platform: TargetPlatform.android);
        final entry = previewEntry('a.txt', size: 2);
        await h.connectRemote([entry]);
        final key = previewCacheKey('srv-1', entry.path, null, 2);
        final owner = await h.cache.reserveProduction(key);
        addTearDown(() => owner?.release());

        h.session.previewFocused();
        await untilPhase(h.session, PreviewPhase.prompt);
        h.session.previewFocused();
        await previewSettle();
        expect(h.producer.specs, isEmpty);

        final cached = await h.cache.prepare(key, extension: 'txt');
        await cached.tempFile.writeAsString('hi');
        await cached.commit();
        final otherKey = previewCacheKey('srv-1', '/srv/home/z.txt', null, 1);
        final other = await h.cache.prepare(otherKey, extension: 'txt');
        await other.tempFile.writeAsString('z');
        await other.commit();
        expect(h.cache.keys, [key, otherKey]);

        // Grant first, then dispose before the waiter's continuation runs.
        owner!.release();
        h.session.dispose();
        await previewSettle();

        expect(h.cache.keys, [key, otherKey]);
        final next = await h.cache
            .reserveProduction(key)
            .timeout(const Duration(seconds: 1));
        expect(next, isNotNull);
        next!.release();
      },
    );

    test('a failed production returns the prompt with the failure card',
        () async {
      final h = await PreviewHarness.create();
      await h.connectRemote([previewEntry('a.txt', size: 2)]);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.prompt);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.producing);
      await untilTrue(() => h.producer.specs.isNotEmpty);
      h.producer.fail(
        0,
        const RemoteFileException(
          kind: RemoteFileErrorKind.other,
          operation: 'preview produce',
          message: 'boom',
        ),
      );
      await untilPhase(h.session, PreviewPhase.prompt);
      expect(h.session.refusal, PreviewRefusal.failed);
    });

    test('a reserved cache lookup failure remains retryable', () async {
      final h = await PreviewHarness.create();
      final entry = previewEntry('a.txt', size: 2);
      await h.connectRemote([entry]);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.prompt);

      final key = previewCacheKey('srv-1', entry.path, null, 2);
      final slot = await h.cache.prepare(key, extension: 'txt');
      await slot.tempFile.writeAsString('hi');
      await slot.commit();

      // A directory at the index path makes lookup's recency persist fail.
      final index = File('${h.tempDir.path}/index.json');
      await index.delete();
      await Directory(index.path).create();

      h.session.previewFocused();
      await untilTrue(() => h.session.refusal == PreviewRefusal.failed);

      expect(h.session.phase, PreviewPhase.prompt);
      expect(h.producer.specs, isEmpty);

      await Directory(index.path).delete();
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.rendered);

      expect(h.session.text?.text, 'hi');
      expect(h.producer.specs, isEmpty);
    });

    test('metadata refusal for a known size over the cache cap',
        () async {
      final h = await PreviewHarness.create(cacheCapacityBytes: 8);
      await h.connectRemote([previewEntry('huge.txt', size: 4096)]);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.rendered);
      expect(h.session.refusal, PreviewRefusal.overCacheCap);
      expect(h.producer.specs, isEmpty);
    });

    test('metadata refusal for a known size over the kind cap', () async {
      final h = await PreviewHarness.create(cacheCapacityBytes: 128 << 20);
      final overKind = (previewKindCapBytes(PreviewKind.image) ?? 0) + 1;
      await h.connectRemote([previewEntry('wall.png', size: overKind)]);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.rendered);
      expect(h.session.refusal, PreviewRefusal.overKindCap);
      expect(h.producer.specs, isEmpty);
    });

    test('a stale completion still commits to the cache, unrendered',
        () async {
      final h = await PreviewHarness.create();
      await h.connectRemote([
        previewEntry('one.txt', size: 2),
        previewEntry('two.txt', size: 2),
      ]);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.prompt);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.producing);

      // Move focus mid-flight: the first production keeps running.
      h.left.setCursorIndex(1);
      await untilPhase(h.session, PreviewPhase.prompt);
      expect(h.session.entry?.name, 'two.txt');

      await h.producer.complete(0, utf8.encode('x'));
      // The commit shells out to chmod, which stretches past a fixed
      // settle under full-suite load: poll for the cache entry.
      final key = previewCacheKey('srv-1', '/srv/home/one.txt', null, 2);
      File? cached;
      for (var i = 0; i < 400 && cached == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        cached = await h.cache.lookup(key);
      }
      expect(cached, isNotNull);
      // The new focus's prompt survived — the stale file landed in the
      // cache only (its key is listed, nothing re-rendered).
      expect(h.session.phase, PreviewPhase.prompt);
      expect(h.session.entry?.name, 'two.txt');
    });

    test(
      'a queued start keeps its original kind and leaves new focus alone',
      () async {
        final h = await PreviewHarness.create(
          platform: TargetPlatform.android,
          cacheCapacityBytes: 128 << 20,
        );
        final image = previewEntry('a-photo.png', size: 4);
        await h.connectRemote([image, previewEntry('z-notes.txt', size: 4)]);
        final local = File('${h.tempDir.path}/peer.png')
          ..writeAsBytesSync(const [1]);
        final comparison = SyncCompareController(
          request: SyncCompareRequest(
            relativePath: 'a-photo.png',
            left: RemoteSyncCompareSource(
              side: SyncSide.left,
              fullPath: image.path,
              snapshot: const EntrySnapshot(kind: EntryKind.file, size: 4),
              serverId: 'srv-1',
            ),
            right: LocalSyncCompareSource(
              side: SyncSide.right,
              fullPath: local.path,
              snapshot: const EntrySnapshot(kind: EntryKind.file, size: 1),
            ),
          ),
          previewCache: h.cache,
          previewProducer: h.producer,
          largeDownloadThresholdBytes: () => 4096,
        );
        addTearDown(comparison.dispose);
        final compared = comparison.start();
        await untilTrue(() => h.producer.specs.isNotEmpty);

        h.session.previewFocused();
        await untilPhase(h.session, PreviewPhase.prompt);
        expect(h.session.kind, PreviewKind.image);
        h.session.previewFocused();
        await previewSettle();
        expect(h.producer.specs, hasLength(1));

        h.left.setCursorIndex(1);
        await untilPhase(h.session, PreviewPhase.prompt);
        h.producer.fail(
          0,
          const RemoteFileException(
            kind: RemoteFileErrorKind.other,
            operation: 'compare',
            message: 'release reservation',
          ),
        );
        await compared;
        await untilTrue(() => h.producer.specs.length == 2);

        expect(h.producer.specs.last.remotePath, image.path);
        expect(h.producer.specs.last.maximumBytes, previewImageKindCapBytes);
        expect(h.session.entry?.name, 'z-notes.txt');
        expect(h.session.phase, PreviewPhase.prompt);
      },
    );

    test(
      'a pending start re-attaches after focus returns to its key',
      () async {
        final h = await PreviewHarness.create(platform: TargetPlatform.android);
        final first = previewEntry('a.txt', size: 2);
        await h.connectRemote([first, previewEntry('b.txt', size: 2)]);
        final key = previewCacheKey('srv-1', first.path, null, 2);
        final owner = await h.cache.reserveProduction(key);
        addTearDown(() => owner?.release());

        h.session.previewFocused();
        await untilPhase(h.session, PreviewPhase.prompt);
        h.session.previewFocused();
        await previewSettle();
        expect(h.producer.specs, isEmpty);

        h.left.setCursorIndex(1);
        await untilTrue(() => h.session.entry?.name == 'b.txt');
        h.left.setCursorIndex(0);
        await untilTrue(() => h.session.entry?.name == 'a.txt');
        await untilPhase(h.session, PreviewPhase.prompt);
        h.session.previewFocused();

        owner!.release();
        await untilTrue(() => h.producer.specs.isNotEmpty);
        await h.producer.complete(0, utf8.encode('hi'));
        await untilPhase(h.session, PreviewPhase.rendered);

        expect(h.session.entry?.name, 'a.txt');
        expect(h.session.text?.text, 'hi');
        expect(h.producer.specs, hasLength(1));
      },
    );

    test('a confirmed pending start re-attaches and can be cancelled',
        () async {
      final h = await PreviewHarness.create(
        platform: TargetPlatform.android,
        thresholdBytes: 8,
      );
      final first = previewEntry('a.txt', size: 100);
      await h.connectRemote([first, previewEntry('b.txt', size: 2)]);
      final key = previewCacheKey('srv-1', first.path, null, 100);
      final owner = await h.cache.reserveProduction(key);
      addTearDown(() => owner?.release());

      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.prompt);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.confirm);
      h.session.confirmDownload();
      await previewSettle();
      expect(h.producer.specs, isEmpty);

      h.left.setCursorIndex(1);
      await untilTrue(() => h.session.entry?.name == 'b.txt');
      h.left.setCursorIndex(0);
      await untilTrue(() => h.session.entry?.name == 'a.txt');
      await previewSettle();
      final phaseAfterReturn = h.session.phase;
      expect(h.session.escape(), isTrue);

      owner!.release();
      await previewSettle();

      expect(phaseAfterReturn, PreviewPhase.producing);
      expect(h.session.phase, PreviewPhase.prompt);
      expect(h.session.refusal, PreviewRefusal.cancelled);
      expect(h.producer.specs, isEmpty);
    });

    test('Esc cancels a confirmed start waiting for cache ownership',
        () async {
      final h = await PreviewHarness.create(
        platform: TargetPlatform.android,
        thresholdBytes: 8,
      );
      final entry = previewEntry('a.txt', size: 100);
      await h.connectRemote([entry]);
      final key = previewCacheKey('srv-1', entry.path, null, 100);
      final owner = await h.cache.reserveProduction(key);
      addTearDown(() => owner?.release());

      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.prompt);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.confirm);
      h.session.confirmDownload();
      await untilPhase(h.session, PreviewPhase.producing);
      expect(h.session.escape(), isTrue);

      owner!.release();
      await previewSettle();

      expect(h.session.phase, PreviewPhase.prompt);
      expect(h.session.refusal, PreviewRefusal.cancelled);
      expect(h.producer.specs, isEmpty);
    });

    test('a cancelled prepare cannot reattach after focus returns',
        () async {
      final prepareStarted = Completer<void>();
      final releasePrepare = Completer<void>();
      addTearDown(() {
        if (!releasePrepare.isCompleted) releasePrepare.complete();
      });
      final h = await PreviewHarness.create(
        platform: TargetPlatform.android,
        afterCacheTempPrepared: () async {
          if (!prepareStarted.isCompleted) prepareStarted.complete();
          await releasePrepare.future;
        },
      );
      await h.connectRemote([
        previewEntry('a.txt', size: 2),
        previewEntry('b.txt', size: 2),
      ]);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.prompt);
      h.session.previewFocused();
      await prepareStarted.future;
      expect(h.session.phase, PreviewPhase.producing);
      expect(h.session.escape(), isTrue);

      h.left.setCursorIndex(1);
      await untilTrue(() => h.session.entry?.name == 'b.txt');
      h.left.setCursorIndex(0);
      await untilTrue(() => h.session.entry?.name == 'a.txt');
      await previewSettle();
      releasePrepare.complete();
      await previewSettle();

      expect(h.session.phase, PreviewPhase.prompt);
      expect(h.session.refusal, PreviewRefusal.cancelled);
      expect(h.producer.specs, isEmpty);
    });

    test('a cancelled prepare accepts an immediate retry', () async {
      final prepareStarted = Completer<void>();
      final releasePrepare = Completer<void>();
      addTearDown(() {
        if (!releasePrepare.isCompleted) releasePrepare.complete();
      });
      final h = await PreviewHarness.create(
        platform: TargetPlatform.android,
        afterCacheTempPrepared: () async {
          if (!prepareStarted.isCompleted) prepareStarted.complete();
          await releasePrepare.future;
        },
      );
      await h.connectRemote([previewEntry('a.txt', size: 2)]);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.prompt);
      h.session.previewFocused();
      await prepareStarted.future;
      expect(h.session.escape(), isTrue);

      h.session.previewFocused();
      releasePrepare.complete();
      await untilTrue(() => h.producer.specs.isNotEmpty);
      expect(h.producer.specs, isNotEmpty);
      await h.producer.complete(0, utf8.encode('hi'));
      await untilPhase(h.session, PreviewPhase.rendered);

      expect(h.session.text?.text, 'hi');
      expect(h.producer.specs, hasLength(1));
    });

    test('Esc on producing cancels the task, keeping the panel', () async {
      final h = await PreviewHarness.create();
      await h.connectRemote([previewEntry('a.txt', size: 2)]);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.prompt);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.producing);
      await untilTrue(() => h.producer.specs.isNotEmpty);

      expect(h.session.escape(), isTrue);
      expect(h.producer.cancels, ['produce-0']);
      await untilPhase(h.session, PreviewPhase.prompt);
      expect(h.workspace.previewPanelHidden, isFalse);
      expect(h.session.refusal, PreviewRefusal.cancelled);
    });

    test('togglePanel opens on the focused item and closes', () async {
      final h = await PreviewHarness.create();
      await h.connectRemote([previewEntry('a.txt', size: 2)]);
      h.session.togglePanel();
      await untilPhase(h.session, PreviewPhase.prompt);
      expect(h.workspace.previewPanelHidden, isFalse);
      h.session.togglePanel();
      expect(h.workspace.previewPanelHidden, isTrue);
    });

    test('cached hit renders without a prompt or a task', () async {
      final h = await PreviewHarness.create();
      final entry = previewEntry('cached.txt', size: 3);
      await h.connectRemote([entry]);
      // Pre-seed the cache under the entry's key.
      final key = previewCacheKey('srv-1', entry.path, null, 3);
      final slot = await h.cache.prepare(key, extension: 'txt');
      await File(slot.tempFile.path).writeAsBytes(utf8.encode('abc'));
      await slot.commit();

      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.rendered);
      expect(h.session.text, isNotNull);
      expect(h.producer.specs, isEmpty);
    });

    test('re-focusing an in-flight item re-attaches to its production',
        () async {
      final h = await PreviewHarness.create();
      await h.connectRemote([
        previewEntry('one.txt', size: 2),
        previewEntry('two.txt', size: 2),
      ]);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.prompt);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.producing);
      await untilTrue(() => h.producer.specs.isNotEmpty);
      h.producer.progress(0, 1, 2);
      expect(h.session.transferred, 1);

      h.left.setCursorIndex(1);
      await untilPhase(h.session, PreviewPhase.prompt);
      h.left.setCursorIndex(0);
      await untilPhase(h.session, PreviewPhase.producing);
      expect(h.session.transferred, 1);
      expect(h.producer.specs, hasLength(1));

      h.producer.progress(0, 2, 2);
      expect(h.session.transferred, 2);
      await h.producer.complete(0, utf8.encode('hi'));
      await untilPhase(h.session, PreviewPhase.rendered);
      expect(h.session.text?.text, 'hi');
    });

    test('no producer: prompt stays honest, canProduce is false',
        () async {
      final h = await PreviewHarness.create(withProducer: false);
      await h.connectRemote([previewEntry('a.txt', size: 2)]);
      expect(h.session.canProduce, isFalse);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.prompt);
      // Space on the prompt cannot start a production.
      h.session.previewFocused();
      await previewSettle();
      expect(h.session.phase, PreviewPhase.prompt);
    });

    test('unpreviewable remote kind renders the metadata card', () async {
      final h = await PreviewHarness.create();
      await h.connectRemote([previewEntry('archive.bin', size: 5)]);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.rendered);
      expect(h.session.kind, PreviewKind.metadata);
      expect(h.producer.specs, isEmpty);
    });

    test('remote directory renders metadata without producing', () async {
      final h = await PreviewHarness.create();
      await h.connectRemote([
        previewEntry('folder', type: RemoteFileType.directory),
      ]);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.rendered);
      expect(h.session.kind, PreviewKind.metadata);
      expect(h.producer.specs, isEmpty);
    });
  });

  group('local previews', () {
    test('a local text file renders immediately', () async {
      final h = await PreviewHarness.create();
      final file = File('${h.tempDir.path}/local.txt')
        ..writeAsStringSync('local body\n');
      await h.connectLocal(h.tempDir, [
        previewEntry('local.txt', size: 11, parent: h.tempDir.path),
      ]);
      expect(file.existsSync(), isTrue);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.rendered);
      expect(h.session.kind, PreviewKind.text);
      expect(h.session.text, isNotNull);
    });

    test('a missing local file reports the missing refusal', () async {
      final h = await PreviewHarness.create();
      final ghost = Directory('${h.tempDir.path}/listing')
        ..createSync();
      await h.connectLocal(ghost, [
        previewEntry('gone.txt', size: 4, parent: ghost.path),
      ]);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.rendered);
      expect(h.session.refusal, PreviewRefusal.missing);
    });
  });

  // D32 (10 §3): the preview renders at the top of the inspector's Info
  // tab, which is shown by default — a passive well that follows the
  // selection. The groups above start from a user-hidden inspector.
  group('Info tab well (D32 default)', () {
    test('the selection evaluates on its own; it never downloads',
        () async {
      final h = await PreviewHarness.create(infoTabShown: true);
      expect(h.workspace.previewPanelHidden, isFalse);
      await h.connectRemote([previewEntry('notes.txt', size: 4)]);
      await untilPhase(h.session, PreviewPhase.prompt);
      expect(h.session.entry?.name, 'notes.txt');
      expect(h.producer.specs, isEmpty);
    });

    test('Space on the prompt card downloads at the first press',
        () async {
      final h = await PreviewHarness.create(infoTabShown: true);
      await h.connectRemote([previewEntry('notes.txt', size: 4)]);
      await untilPhase(h.session, PreviewPhase.prompt);

      expect(h.session.previewFocused(), isTrue);
      await untilPhase(h.session, PreviewPhase.producing);
      await untilTrue(() => h.producer.specs.isNotEmpty);
      expect(h.producer.specs, hasLength(1));
      await h.producer.complete(0, utf8.encode('hey\n'));
      await untilPhase(h.session, PreviewPhase.rendered);
      expect(h.session.kind, PreviewKind.text);
    });

    test('a local text file renders on selection alone', () async {
      final h = await PreviewHarness.create(infoTabShown: true);
      File('${h.tempDir.path}/local.txt').writeAsStringSync('body\n');
      await h.connectLocal(h.tempDir, [
        previewEntry('local.txt', size: 5, parent: h.tempDir.path),
      ]);
      await untilPhase(h.session, PreviewPhase.rendered);
      expect(h.session.text, isNotNull);
    });

    test('Esc on the prompt or a rendered well falls through and keeps '
        'the inspector', () async {
      final h = await PreviewHarness.create(infoTabShown: true);
      await h.connectRemote([previewEntry('notes.txt', size: 4)]);
      await untilPhase(h.session, PreviewPhase.prompt);
      expect(h.session.escape(), isFalse);
      expect(h.session.phase, PreviewPhase.prompt);

      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.producing);
      await untilTrue(() => h.producer.specs.isNotEmpty);
      await h.producer.complete(0, utf8.encode('hey\n'));
      await untilPhase(h.session, PreviewPhase.rendered);
      expect(h.session.escape(), isFalse);
      expect(h.session.phase, PreviewPhase.rendered);
      expect(h.workspace.inspectorHidden, isFalse);
    });

    test('another inspector tab parks the well; back on Info it '
        'evaluates the current selection', () async {
      final h = await PreviewHarness.create(infoTabShown: true);
      h.workspace.selectInspectorTab(InspectorTab.transfers);
      expect(h.workspace.previewPanelHidden, isTrue);
      await h.connectRemote([previewEntry('notes.txt', size: 4)]);
      await previewSettle();
      expect(h.session.phase, PreviewPhase.idle);

      // Back on Info, the well catches up with the unchanged selection.
      h.workspace.selectInspectorTab(InspectorTab.info);
      await untilPhase(h.session, PreviewPhase.prompt);
      expect(h.session.phase, PreviewPhase.prompt);
      expect(h.session.entry?.name, 'notes.txt');
    });

    test('a rendered well never returns showing a file the selection '
        'left while it was hidden', () async {
      final h = await PreviewHarness.create(infoTabShown: true);
      File('${h.tempDir.path}/a.txt').writeAsStringSync('alpha\n');
      File('${h.tempDir.path}/b.txt').writeAsStringSync('bravo\n');
      await h.connectLocal(h.tempDir, [
        previewEntry('a.txt', size: 6, parent: h.tempDir.path),
        previewEntry('b.txt', size: 6, parent: h.tempDir.path),
      ]);
      await untilPhase(h.session, PreviewPhase.rendered);
      expect(h.session.entry?.name, 'a.txt');

      // Hiding parks the well; the cursor moves while it is hidden.
      h.workspace.toggleInspector();
      expect(h.session.phase, PreviewPhase.idle);
      expect(h.session.text, isNull);
      h.left.setCursorIndex(1);
      await previewSettle();
      expect(h.session.phase, PreviewPhase.idle);

      // Re-showing (the inspector toggle, not a preview verb) renders
      // the file the cursor is on now.
      h.workspace.toggleInspector();
      await untilPhase(h.session, PreviewPhase.rendered);
      expect(h.session.entry?.name, 'b.txt');
      expect(h.session.file?.path, endsWith('b.txt'));
    });
  });

  group('Quick Look on every desktop (D32)', () {
    for (final platform in [TargetPlatform.linux, TargetPlatform.windows]) {
      test('${platform.name}: Space opens Quick Look and toggles it shut, '
          'never hiding the inspector', () async {
        final h = await PreviewHarness.create(
          platform: platform,
          quickLookAvailable: true,
          infoTabShown: true,
        );
        File('${h.tempDir.path}/one.txt').writeAsStringSync('hi\n');
        await h.connectLocal(h.tempDir, [
          previewEntry('one.txt', size: 3, parent: h.tempDir.path),
        ]);
        // The Info tab's docked well renders on its own.
        await untilPhase(h.session, PreviewPhase.rendered);

        expect(h.session.previewFocused(), isTrue);
        await untilTrue(() => h.session.quickLookActive);
        expect(h.quickLook.shows.single.$1.single, endsWith('one.txt'));
        expect(h.workspace.inspectorHidden, isFalse);
        expect(h.workspace.previewPanelHidden, isFalse);
        expect(h.session.phase, PreviewPhase.rendered);

        h.session.previewFocused();
        await untilTrue(() => !h.session.quickLookActive);
        expect(h.quickLook.hideCalls, 1);
        expect(h.workspace.inspectorHidden, isFalse);
        expect(h.session.phase, PreviewPhase.rendered);
      });

      test('${platform.name}: the Info well keeps following the selection '
          'while Quick Look is open', () async {
        final h = await PreviewHarness.create(
          platform: platform,
          quickLookAvailable: true,
          infoTabShown: true,
        );
        File('${h.tempDir.path}/a.txt').writeAsStringSync('alpha\n');
        File('${h.tempDir.path}/b.txt').writeAsStringSync('bravo\n');
        await h.connectLocal(h.tempDir, [
          previewEntry('a.txt', size: 6, parent: h.tempDir.path),
          previewEntry('b.txt', size: 6, parent: h.tempDir.path),
        ]);
        await untilPhase(h.session, PreviewPhase.rendered);
        h.session.previewFocused();
        await untilTrue(() => h.session.quickLookActive);

        h.left.setCursorIndex(1);
        await untilTrue(() => h.quickLook.updates.isNotEmpty);
        expect(h.quickLook.updates.last.$1.single, endsWith('b.txt'));
        await untilTrue(
          () => h.session.file?.path.endsWith('b.txt') ?? false,
        );
        expect(h.session.entry?.name, 'b.txt');
        expect(h.session.text?.text, 'bravo\n');
      });

      test('${platform.name}: Esc closes Quick Look', () async {
        final h = await PreviewHarness.create(
          platform: platform,
          quickLookAvailable: true,
        );
        await h.connectLocal(h.tempDir, [
          previewEntry('one.txt', size: 2, parent: h.tempDir.path),
        ]);
        h.session.previewFocused();
        await untilTrue(() => h.session.quickLookActive);

        expect(h.session.escape(), isTrue);
        expect(h.session.quickLookActive, isFalse);
        expect(h.quickLook.hideCalls, 1);
        // The next Esc belongs to the lower tiers again.
        expect(h.session.escape(), isFalse);
      });
    }

    test('touch platforms keep the Info tab as Space\'s surface', () async {
      final h = await PreviewHarness.create(
        platform: TargetPlatform.android,
        quickLookAvailable: true,
      );
      await h.connectRemote([previewEntry('a.txt', size: 2)]);
      expect(h.session.previewFocused(), isTrue);
      await untilPhase(h.session, PreviewPhase.prompt);
      expect(h.workspace.previewPanelHidden, isFalse);
      expect(h.quickLook.shows, isEmpty);
    });
  });

  group('Quick Look (macOS platform)', () {
    test('unavailable channel falls back to the panel', () async {
      final h = await PreviewHarness.create(
        platform: TargetPlatform.macOS,
        quickLookAvailable: false,
      );
      await h.connectRemote([previewEntry('a.txt', size: 2)]);
      expect(h.session.previewFocused(), isTrue);
      await untilPhase(h.session, PreviewPhase.prompt);
      expect(h.workspace.previewPanelHidden, isFalse);
      expect(h.quickLook.shows, isEmpty);
    });

    test('local Space opens the native panel; Space again closes',
        () async {
      final h = await PreviewHarness.create(
        platform: TargetPlatform.macOS,
        quickLookAvailable: true,
      );
      await h.connectLocal(h.tempDir, [
        previewEntry('one.txt', size: 2, parent: h.tempDir.path),
      ]);
      h.session.previewFocused();
      await untilTrue(() => h.quickLook.shows.isNotEmpty);
      expect(h.quickLook.shows.single.$1.single, contains('one.txt'));
      await untilTrue(() => h.session.quickLookActive);
      expect(h.workspace.previewPanelHidden, isTrue);

      h.session.previewFocused();
      await untilTrue(() => h.quickLook.hideCalls > 0);
      await untilTrue(() => !h.session.quickLookActive);
    });

    test('remote Space produces then opens the native panel', () async {
      final h = await PreviewHarness.create(
        platform: TargetPlatform.macOS,
        quickLookAvailable: true,
      );
      await h.connectRemote([previewEntry('photo.png', size: 10)]);
      h.session.previewFocused();
      await untilTrue(
        () => h.session.quickLookCard == QuickLookCardKind.producing,
      );
      await untilTrue(() => h.producer.specs.isNotEmpty);

      await h.producer.complete(0, List.filled(10, 7));
      await untilTrue(() => h.quickLook.shows.isNotEmpty);
      final producedPath = h.quickLook.shows.single.$1.single;
      expect(File(producedPath).existsSync(), isTrue);
      expect(h.session.quickLookActive, isTrue);
      expect(h.session.quickLookCard, QuickLookCardKind.none);
    });

    test('Space goes to Quick Look even while the Info tab shows the '
        'preview well (D32)', () async {
      final h = await PreviewHarness.create(
        platform: TargetPlatform.macOS,
        quickLookAvailable: true,
        infoTabShown: true,
      );
      await h.connectRemote([previewEntry('a.txt', size: 2)]);
      await untilPhase(h.session, PreviewPhase.prompt);
      h.session.previewFocused();
      // The Quick Look leg answers — its producing card, not the Info
      // tab's prompt-card download.
      await untilTrue(
        () => h.session.quickLookCard == QuickLookCardKind.producing,
      );
      await untilTrue(() => h.producer.specs.isNotEmpty);
      await h.producer.complete(0, utf8.encode('hi'));
      await untilTrue(() => h.quickLook.shows.isNotEmpty);
      expect(h.session.quickLookActive, isTrue);
      expect(h.workspace.previewPanelHidden, isFalse);
    });

    test('the native close edge clears Quick Look state', () async {
      final h = await PreviewHarness.create(
        platform: TargetPlatform.macOS,
        quickLookAvailable: true,
      );
      await h.connectLocal(h.tempDir, [
        previewEntry('one.txt', size: 2, parent: h.tempDir.path),
      ]);
      h.session.previewFocused();
      await untilTrue(() => h.session.quickLookActive);
      h.quickLook.emitClosed();
      await untilTrue(() => !h.session.quickLookActive);
    });

    test('Esc on the producing overlay cancels the production', () async {
      final h = await PreviewHarness.create(
        platform: TargetPlatform.macOS,
        quickLookAvailable: true,
      );
      await h.connectRemote([previewEntry('a.txt', size: 2)]);
      h.session.previewFocused();
      await untilTrue(
        () => h.session.quickLookCard == QuickLookCardKind.producing,
      );
      // The cancel lands once the produce task exists (the pre-ticket
      // window aborts the pending start instead).
      await untilTrue(() => h.producer.specs.isNotEmpty);
      expect(h.session.escape(), isTrue);
      expect(h.producer.cancels, ['produce-0']);
    });

    test('over-threshold remote Space shows the confirm card', () async {
      final h = await PreviewHarness.create(
        platform: TargetPlatform.macOS,
        quickLookAvailable: true,
        thresholdBytes: 8,
      );
      await h.connectRemote([previewEntry('big.bin', size: 900)]);
      h.session.previewFocused();
      await untilTrue(
        () => h.session.quickLookCard == QuickLookCardKind.confirm,
      );
      expect(h.producer.specs, isEmpty);

      h.session.quickLookConfirm();
      await untilTrue(
        () => h.session.quickLookCard == QuickLookCardKind.producing,
      );
      await untilTrue(() => h.producer.specs.isNotEmpty);
    });

    test('a Quick Look confirm is retargeted before it can be reused',
        () async {
      final lookupStarted = Completer<void>();
      final releaseLookup = Completer<void>();
      addTearDown(() {
        if (!releaseLookup.isCompleted) releaseLookup.complete();
      });
      final h = await PreviewHarness.create(
        platform: TargetPlatform.macOS,
        quickLookAvailable: true,
        thresholdBytes: 8,
        lookupCacheFileExists: (file) async {
          if (!lookupStarted.isCompleted) lookupStarted.complete();
          await releaseLookup.future;
          return false;
        },
      );
      final second = previewEntry('b.bin', size: 200);
      await h.connectRemote([previewEntry('a.bin', size: 100), second]);
      final secondKey = previewCacheKey('srv-1', second.path, null, 200);
      final cached = await h.cache.prepare(secondKey, extension: 'bin');
      await cached.tempFile.writeAsString('stale');
      await cached.commit();
      h.session.previewFocused();
      await untilTrue(
        () => h.session.quickLookCard == QuickLookCardKind.confirm,
      );

      h.left.setCursorIndex(1);
      await previewSettle();
      final followedSelection = lookupStarted.isCompleted;
      final cardAfterFocus = h.session.quickLookCard;
      h.session.quickLookConfirm();
      releaseLookup.complete();
      await untilTrue(
        () => h.session.quickLookCard == QuickLookCardKind.confirm,
      );

      expect(followedSelection, isTrue);
      expect(cardAfterFocus, QuickLookCardKind.none);
      expect(h.session.entry?.name, 'b.bin');
      expect(h.producer.specs, isEmpty);
    });

    test('a local focus replaces a pending remote Quick Look request',
        () async {
      final h = await PreviewHarness.create(
        platform: TargetPlatform.macOS,
        quickLookAvailable: true,
        thresholdBytes: 8,
      );
      await h.connectRemote([previewEntry('big.bin', size: 100)]);
      h.session.previewFocused();
      await untilTrue(
        () => h.session.quickLookCard == QuickLookCardKind.confirm,
      );

      final local = File('${h.tempDir.path}/local.txt')
        ..writeAsStringSync('local');
      await h.connectRightLocal(h.tempDir, [
        previewEntry(
          'local.txt',
          size: 5,
          parent: h.tempDir.path,
        ),
      ]);
      h.workspace.setActivePane(h.workspace.right);
      await previewSettle();
      final openedLocal = h.quickLook.shows.isNotEmpty;
      final activeAfterFocus = h.session.quickLookActive;
      h.session.previewFocused();
      await previewSettle();

      expect(openedLocal, isTrue);
      expect(activeAfterFocus, isTrue);
      expect(h.quickLook.shows.single.$1, [local.path]);
      expect(h.quickLook.hideCalls, 1);
    });

    test('a local focus change retargets a pending Quick Look open',
        () async {
      final quickLook = _BlockingQuickLookChannel();
      addTearDown(quickLook.releaseDelivery);
      final h = await PreviewHarness.create(
        platform: TargetPlatform.macOS,
        quickLook: quickLook,
      );
      final first = File('${h.tempDir.path}/a.txt')..writeAsStringSync('a');
      final second = File('${h.tempDir.path}/b.txt')..writeAsStringSync('b');
      await h.connectLocal(h.tempDir, [
        previewEntry('a.txt', size: 1, parent: h.tempDir.path),
        previewEntry('b.txt', size: 1, parent: h.tempDir.path),
      ]);

      h.session.previewFocused();
      await quickLook.deliveryStarted.future;
      h.left.setCursorIndex(1);
      await previewSettle();
      quickLook.releaseDelivery();
      await untilTrue(() => h.session.quickLookActive);

      expect(quickLook.shows.first.$1, [first.path]);
      expect(quickLook.shows.last.$1, [second.path]);
    });

    test('a pane switch retargets a pending availability check', () async {
      final quickLook = _BlockingAvailabilityQuickLookChannel();
      addTearDown(quickLook.releaseAvailability);
      final h = await PreviewHarness.create(
        platform: TargetPlatform.macOS,
        quickLook: quickLook,
      );
      final left = File('${h.tempDir.path}/left.txt')
        ..writeAsStringSync('left');
      final right = File('${h.tempDir.path}/right.txt')
        ..writeAsStringSync('right');
      await h.connectLocal(h.tempDir, [
        previewEntry('left.txt', size: 4, parent: h.tempDir.path),
      ]);
      await h.connectRightLocal(h.tempDir, [
        previewEntry('right.txt', size: 5, parent: h.tempDir.path),
      ]);

      h.session.previewFocused();
      await quickLook.availabilityStarted.future;
      h.workspace.setActivePane(h.workspace.right);
      quickLook.releaseAvailability();
      await untilTrue(() => h.session.quickLookActive);

      expect(quickLook.shows, hasLength(1));
      expect(quickLook.shows.single.$1, [right.path]);
      expect(quickLook.shows.single.$1, isNot([left.path]));
    });

    test('refocusing a gate-parked production restores its card', () async {
      final h = await PreviewHarness.create(
        platform: TargetPlatform.macOS,
        quickLookAvailable: true,
        thresholdBytes: 8,
      );
      await h.connectRemote([
        previewEntry('a.bin'),
        previewEntry('b.bin'),
      ]);
      h.session.previewFocused();
      await untilTrue(() => h.producer.specs.isNotEmpty);
      final firstGate = h.producer.specs.first.gate!;
      firstGate.wrap(const NullByteSink()).add(List.filled(16, 0));
      await untilTrue(
        () => h.session.quickLookCard == QuickLookCardKind.gateConfirm,
      );

      h.left.setCursorIndex(1);
      await untilTrue(() => h.producer.specs.length == 2);
      h.left.setCursorIndex(0);
      await previewSettle();
      final restoredCard = h.session.quickLookCard;
      h.session.quickLookKeepDownloading();

      expect(restoredCard, QuickLookCardKind.gateConfirm);
      expect(firstGate.isAwaitingConfirmation, isFalse);
      expect(h.producer.specs, hasLength(2));
    });

    test('pending cancellation updates Quick Look and the Info well',
        () async {
      final h = await PreviewHarness.create(
        platform: TargetPlatform.macOS,
        quickLookAvailable: true,
        infoTabShown: true,
      );
      final first = previewEntry('a.txt', size: 2);
      await h.connectRemote([
        first,
        previewEntry('b.txt', size: 2 << 20),
      ]);
      final key = previewCacheKey('srv-1', first.path, null, 2);
      final owner = await h.cache.reserveProduction(key);
      addTearDown(() => owner?.release());
      await untilPhase(h.session, PreviewPhase.prompt);

      h.session.previewFocused();
      await untilTrue(
        () => h.session.quickLookCard == QuickLookCardKind.producing,
      );
      h.left.setCursorIndex(1);
      await untilTrue(
        () => h.session.quickLookCard == QuickLookCardKind.refused,
      );
      h.left.setCursorIndex(0);
      await untilTrue(
        () => h.session.quickLookCard == QuickLookCardKind.producing,
      );
      await untilPhase(h.session, PreviewPhase.producing);

      expect(h.session.escape(), isTrue);
      owner!.release();
      await previewSettle();

      expect(h.session.quickLookCard, QuickLookCardKind.none);
      expect(h.session.phase, PreviewPhase.prompt);
      expect(h.session.refusal, PreviewRefusal.cancelled);
      expect(h.producer.specs, isEmpty);
    });

    test('Quick Look accepts an immediate retry of a cancelled start',
        () async {
      final h = await PreviewHarness.create(
        platform: TargetPlatform.macOS,
        quickLookAvailable: true,
      );
      final entry = previewEntry('a.txt', size: 2);
      await h.connectRemote([entry]);
      final key = previewCacheKey('srv-1', entry.path, null, 2);
      final owner = await h.cache.reserveProduction(key);
      addTearDown(() => owner?.release());

      h.session.previewFocused();
      await untilTrue(
        () => h.session.quickLookCard == QuickLookCardKind.producing,
      );
      expect(h.session.escape(), isTrue);

      h.session.previewFocused();
      owner!.release();
      await untilTrue(() => h.producer.specs.isNotEmpty);
      expect(h.producer.specs, isNotEmpty);
      await h.producer.complete(0, utf8.encode('hi'));
      await untilTrue(() => h.session.quickLookActive);

      expect(h.quickLook.shows, hasLength(1));
      expect(h.producer.specs, hasLength(1));
    });

    test('a direct cache lookup failure leaves Quick Look retryable', () async {
      final h = await PreviewHarness.create(
        platform: TargetPlatform.macOS,
        quickLookAvailable: true,
      );
      final entry = previewEntry('cached.txt', size: 2);
      await h.connectRemote([entry]);
      final key = previewCacheKey('srv-1', entry.path, null, 2);
      final slot = await h.cache.prepare(key, extension: 'txt');
      await slot.tempFile.writeAsString('hi');
      await slot.commit();

      final index = File('${h.tempDir.path}/index.json');
      await index.delete();
      await Directory(index.path).create();

      h.session.previewFocused();
      await previewSettle();
      await Directory(index.path).delete();

      expect(h.session.quickLookCard, QuickLookCardKind.none);
      expect(h.quickLook.shows, isEmpty);

      h.session.previewFocused();
      await untilTrue(() => h.quickLook.shows.isNotEmpty);
      expect(h.session.quickLookActive, isTrue);
    });

    test(
      'a reserved cache lookup failure leaves Quick Look retryable',
      () async {
        final h = await PreviewHarness.create(
          platform: TargetPlatform.macOS,
          quickLookAvailable: true,
        );
        final entry = previewEntry('cached.txt', size: 2);
        await h.connectRemote([entry]);
        final key = previewCacheKey('srv-1', entry.path, null, 2);
        final owner = await h.cache.reserveProduction(key);
        addTearDown(() => owner?.release());

        h.session.previewFocused();
        await untilTrue(
          () => h.session.quickLookCard == QuickLookCardKind.producing,
        );
        final slot = await h.cache.prepare(key, extension: 'txt');
        await slot.tempFile.writeAsString('hi');
        await slot.commit();

        final index = File('${h.tempDir.path}/index.json');
        await index.delete();
        await Directory(index.path).create();
        owner!.release();
        await untilTrue(
          () => h.session.quickLookCard == QuickLookCardKind.none,
        );
        await Directory(index.path).delete();

        expect(h.session.quickLookCard, QuickLookCardKind.none);

        h.session.previewFocused();
        await untilTrue(() => h.quickLook.shows.isNotEmpty);
        expect(h.session.quickLookActive, isTrue);
      },
    );

    test(
      'a cached waiter releases its key before Quick Look delivery',
      () async {
        final quickLook = _BlockingQuickLookChannel();
        addTearDown(quickLook.releaseDelivery);
        final h = await PreviewHarness.create(
          platform: TargetPlatform.macOS,
          quickLook: quickLook,
        );
        final entry = previewEntry('cached.png', size: 3);
        await h.connectRemote([entry]);
        final key = previewCacheKey('srv-1', entry.path, null, 3);
        final owner = await h.cache.reserveProduction(key);
        addTearDown(() => owner?.release());

        h.session.previewFocused();
        await untilTrue(
          () => h.session.quickLookCard == QuickLookCardKind.producing,
        );
        final slot = await h.cache.prepare(key, extension: 'png');
        await slot.tempFile.writeAsBytes(const [1, 2, 3]);
        await slot.commit();
        owner!.release();
        await quickLook.deliveryStarted.future;

        var nextAcquired = false;
        final nextFuture = h.cache.reserveProduction(key).then((reservation) {
          nextAcquired = true;
          return reservation;
        });
        await previewSettle();
        final acquiredBeforeDeliveryFinished = nextAcquired;
        quickLook.releaseDelivery();
        final next = await nextFuture;
        next?.release();

        expect(acquiredBeforeDeliveryFinished, isTrue);
      },
    );
  });

  group('selection header', () {
    test('count, summed bytes, and unknown-size rows stay honest',
        () async {
      final h = await PreviewHarness.create();
      await h.connectRemote([
        previewEntry('a.txt', size: 10),
        previewEntry('b.txt', size: 20),
        previewEntry('c.txt'),
      ]);
      h.left.setCursorIndex(0);
      h.left.setCursorIndex(2, update: SelectionUpdate.range);
      h.session.togglePanel();
      await previewSettle();
      expect(h.session.selectionCount, 3);
      expect(h.session.selectionBytes, 30);
      expect(h.session.selectionUnknownSizes, 1);
    });
  });
}

final class _BlockingQuickLookChannel implements QuickLookChannel {
  final deliveryStarted = Completer<void>();
  final _deliveryRelease = Completer<void>();
  final shows = <(List<String>, int)>[];

  void releaseDelivery() {
    if (!_deliveryRelease.isCompleted) _deliveryRelease.complete();
  }

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<void> showPreview(List<String> paths, int index) async {
    shows.add((paths, index));
    if (!deliveryStarted.isCompleted) deliveryStarted.complete();
    await _deliveryRelease.future;
  }

  @override
  Future<void> updatePreview(List<String> paths, int index) =>
      showPreview(paths, index);

  @override
  Future<void> hidePreview() async {}

  @override
  Future<bool> isVisible() async => false;

  @override
  Stream<void> get onClosed => const Stream.empty();
}

final class _BlockingAvailabilityQuickLookChannel
    implements QuickLookChannel {
  final availabilityStarted = Completer<void>();
  final _availabilityRelease = Completer<void>();
  final shows = <(List<String>, int)>[];

  void releaseAvailability() {
    if (!_availabilityRelease.isCompleted) _availabilityRelease.complete();
  }

  @override
  Future<bool> isAvailable() async {
    if (!availabilityStarted.isCompleted) availabilityStarted.complete();
    await _availabilityRelease.future;
    return true;
  }

  @override
  Future<void> showPreview(List<String> paths, int index) async {
    shows.add((paths, index));
  }

  @override
  Future<void> updatePreview(List<String> paths, int index) =>
      showPreview(paths, index);

  @override
  Future<void> hidePreview() async {}

  @override
  Future<bool> isVisible() async => false;

  @override
  Stream<void> get onClosed => const Stream.empty();
}

final class _LateCompletingPreviewProducer implements PreviewProducer {
  final specs = <PreviewProduceSpec>[];
  final cancels = <String>[];
  final _result = Completer<RemoteFileEntry>();

  @override
  PreviewProduceTicket start(PreviewProduceSpec spec) {
    specs.add(spec);
    return PreviewProduceTicket(taskId: 'late-produce', result: _result.future);
  }

  @override
  void cancel(String taskId) {
    cancels.add(taskId);
  }

  Future<void> complete(List<int> bytes) async {
    final spec = specs.single;
    await File(spec.destinationPath).writeAsBytes(bytes, flush: true);
    _result.complete(
      RemoteFileEntry(
        path: spec.remotePath,
        name: spec.remotePath.split('/').last,
        type: RemoteFileType.file,
        size: bytes.length,
      ),
    );
  }
}
