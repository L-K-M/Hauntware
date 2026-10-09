import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_ui/ghost_ui.dart' show encodeBadgeImage;
import 'package:seance_core/seance_core.dart';

/// The shared badge encoder (ghost_ui, tested there) against Séance's own
/// record limits: what it produces must survive the protocol's validation.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// A [width]×[height] PNG: a solid field with a centred circle, so a
  /// centre-cropped result stays recognisable beyond its bare dimensions.
  Future<Uint8List> png(int width, int height) async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      ui.Paint()..color = const ui.Color(0xFF3366CC),
    );
    canvas.drawCircle(
      ui.Offset(width / 2, height / 2),
      width / 4,
      ui.Paint()..color = const ui.Color(0xFFFFCC00),
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(width, height);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    picture.dispose();
    image.dispose();
    return data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

  test('the result is a PNG the protocol will carry', () async {
    final result = await encodeBadgeImage(
      await png(512, 512),
      maxBytes: kMaxServerIconImageBytes,
    );
    // The whole point of the ceiling: whatever this produces has to survive
    // the validation a record goes through, or an import would be accepted
    // here and dropped on the next read.
    expect(result.failure, isNull);
    final stored = encodeServerIconImage(result.image!.png);
    expect(stored, isNotNull);
    expect(decodeServerIconImage(stored!), result.image!.png);
  });
}
