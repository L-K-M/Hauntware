import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/pin_publication_controller.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/fake_engine.dart';

void main() {
  late FakeEngineClient engine;

  setUp(() => engine = FakeEngineClient());
  tearDown(() => engine.close());

  PinPublicationController controller({PinPublicationState? initial}) {
    final pins = PinPublicationController(engine, initial: initial);
    addTearDown(pins.dispose);
    return pins;
  }

  test('nothing is offered or sent while no release is named', () async {
    final pins = controller();

    expect(pins.value, const PinPublication());
    await expectLater(
      pins.setAsserted(true),
      throwsA(isA<PinPublicationNotChangedException>()),
    );
    expect(engine.sentOfType<SetPinPublication>(), isEmpty);
  });

  test('an assertion completes once the engine reports it kept', () async {
    final pins = controller(
      initial: const PinPublicationState(release: '2026.11.0'),
    );
    expect(pins.value.release, '2026.11.0');

    final asserted = pins.setAsserted(true);
    final request =
        engine.sentOfType<SetPinPublication>().single as SetPinPublication;
    expect(request.asserted, isTrue);
    engine.emit(
      const PinPublicationState(release: '2026.11.0', asserted: true),
    );
    await asserted;
    expect(pins.value.asserted, isTrue);

    // Already in force: nothing more is sent.
    await pins.setAsserted(true);
    expect(engine.sentOfType<SetPinPublication>(), hasLength(1));
  });

  test('a change the engine did not keep, or refused, throws', () async {
    final pins = controller(
      initial: const PinPublicationState(release: '2026.11.0'),
    );

    final kept = pins.setAsserted(true);
    engine.emit(const PinPublicationState(release: '2026.11.0'));
    await expectLater(kept, throwsA(isA<PinPublicationNotChangedException>()));

    final refused = pins.setAsserted(true);
    engine.emit(const RequestRejected('SetPinPublication', 'no release'));
    await expectLater(
      refused,
      throwsA(isA<PinPublicationNotChangedException>()),
    );
  });
}
