import 'dart:convert';

import 'package:klabautermann_docker/klabautermann_docker.dart';
import 'package:test/test.dart';

import '../harness.dart';

Object? fixtureJson(String name) => jsonDecode(fixtureString(name));

void main() {
  group('image list', () {
    test('the Containers count is null below the 1.51 gate', () {
      final r = parseImageSummaries(
        fixtureJson('images-1.52.json'),
        includeContainerCount: false,
      );
      expect(r.warnings, isEmpty);
      expect(r.value, hasLength(2));
      expect(r.value.first.containers, isNull);
      expect(r.value.first.repoTags, ['alpine:3.21']);
      expect(r.value.first.isDangling, isFalse);
    });

    test('reads the Containers count and dangling flag at 1.55', () {
      final r = parseImageSummaries(
        fixtureJson('images-1.55.json'),
        includeContainerCount: true,
      );
      expect(r.warnings, isEmpty);
      expect(r.value.first.containers, 3);
      expect(r.value.first.inUse, isTrue);
      expect(r.value[1].containers, 0);
      expect(r.value[1].isDangling, isTrue);
    });

    test('never throws on malformed daemon input', () {
      expect(parseImageSummaries(null).warnings, isNotEmpty);
      expect(parseImageSummaries(const <Object?>[1]).warnings, isNotEmpty);
    });
  });

  group('image inspect', () {
    test('masks env and reads repo digests', () {
      final r = parseImageInspect(fixtureJson('image-inspect-1.55.json'));
      expect(r.warnings, isEmpty);
      final image = r.value;
      expect(image.architecture, 'amd64');
      expect(image.os, 'linux');
      expect(image.config!.exposedPorts, ['80/tcp']);
      final env = {for (final e in image.config!.env) e.name: e.value};
      expect(env['CI_TOKEN']!.isMasked, isTrue);
      expect(env['CI_TOKEN']!.reveal(), 'glpat-xxxxxxxxxxxx');
      expect(env['PATH']!.isMasked, isFalse);
      expect(
        image.digestFor('alpine'),
        'sha256:abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd',
      );
      expect(image.digestFor('missing'), isNull);
    });

    test('never throws on a non-object inspect', () {
      expect(parseImageInspect(null).warnings, isNotEmpty);
    });

    // Spike S8 (D68): the containerd store's Descriptor and the index
    // children that `manifests=1` lists; only images present locally
    // count, attestations never.
    test('reads the containerd Descriptor and available image children', () {
      const index =
          'sha256:2e0b81d60597f449baa56dc25d355367869d2dca4cd57e866f1e2b52af3eb55f';
      const amd64 =
          'sha256:dc92f017beea8e7f43263073d717f7bc011228c95d5312e440deb4d035bb4eec';
      final r = parseImageInspect({
        'Id': 'sha256:$index',
        'RepoDigests': ['alpine@$index'],
        'Descriptor': {
          'mediaType': 'application/vnd.oci.image.index.v1+json',
          'digest': index,
          'size': 9218,
        },
        'Manifests': [
          {
            'Descriptor': {'digest': amd64},
            'Kind': 'image',
            'Available': true,
          },
          {
            'Descriptor': {'digest': 'sha256:ae0881df4bf2'},
            'Kind': 'attestation',
            'Available': true,
          },
          {
            'Descriptor': {'digest': 'sha256:3e07a4f627d1'},
            'Kind': 'image',
            'Available': false,
          },
        ],
      });
      expect(r.warnings, isEmpty);
      expect(r.value.descriptorDigest, index);
      expect(r.value.availableChildDigests, [amd64]);
    });

    test('the classic store has neither', () {
      final image = parseImageInspect(
        fixtureJson('image-inspect-1.55.json'),
      ).value;
      expect(image.descriptorDigest, isNull);
      expect(image.availableChildDigests, isEmpty);
    });
  });

  group('image history (IMG-04)', () {
    test('reads each layer, a missing id as none and the placeholder tag '
        'as no tag', () {
      final r = parseImageHistory([
        {
          'Id': '<missing>',
          'Created': 1750000000,
          'CreatedBy': 'RUN make',
          'Size': 10,
          'Tags': ['<none>:<none>'],
          'Comment': '',
        },
      ]);
      final layer = r.value.single;
      expect(layer.id, isNull);
      expect(layer.createdBy, 'RUN make');
      expect((layer.size, layer.comment), (10, null));
      expect(layer.tags, isEmpty);
      expect(
        layer.created,
        DateTime.fromMillisecondsSinceEpoch(1750000000000, isUtc: true),
      );
      expect(r.warnings, isEmpty);
    });

    test('never throws on a non-array history', () {
      expect(parseImageHistory({}).warnings, isNotEmpty);
    });
  });
}
