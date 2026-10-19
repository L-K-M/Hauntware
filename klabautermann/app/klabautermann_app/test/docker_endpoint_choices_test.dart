// DockerEndpointChoices (M3 D20): a choice whose save failed is saved
// again when it is chosen again, and only then.
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/docker_endpoint_choices.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

void main() {
  test('choosing a choice whose save failed saves it again', () async {
    final saves = <DockerEndpointOverride?>[];
    var fail = true;
    final choices = DockerEndpointChoices(
      save: (_, override) async {
        saves.add(override);
        if (fail) throw StateError('read-only');
      },
    );
    addTearDown(choices.dispose);
    const socket = DockerEndpointDetected('/run/docker.sock');

    await expectLater(choices.choose('srv', socket), throwsStateError);
    expect(choices.choiceFor('srv'), socket);

    fail = false;
    await choices.choose('srv', socket);
    expect(saves, hasLength(2));

    await choices.choose('srv', socket);
    expect(saves, hasLength(2), reason: 'a saved choice changes nothing');
  });
}
