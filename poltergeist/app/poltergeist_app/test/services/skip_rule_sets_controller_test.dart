import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/skip_rule_sets.dart';
import 'package:poltergeist_app/services/skip_rule_sets_controller.dart';

SkipRuleSet _set(String name, List<String> patterns) =>
    SkipRuleSet(name: name, patterns: patterns);

void main() {
  test('without writers, changes stay in memory and notify', () async {
    final sets = SkipRuleSetsController();
    addTearDown(sets.dispose);
    var notified = 0;
    sets.addListener(() => notified++);

    await sets.put(_set('Web', ['*.log']));
    await sets.put(_set('Site', ['*.log']), replacing: 'Web');
    await sets.put(_set('Docs', ['_site/']));
    await sets.remove('site');

    expect(sets.value, [
      _set('Docs', ['_site/']),
    ]);
    expect(notified, 4);
  });

  test('publishes the list the store wrote, not its own copy', () async {
    // A launch whose read failed starts empty; the store still holds Web.
    final stored = [
      _set('Web', ['*.log']),
    ];
    final sets = SkipRuleSetsController(
      put: (set, {replacing}) async =>
          putSkipRuleSetInto(stored, set, replacing: replacing),
      remove: (name) async => removeSkipRuleSetFrom(stored, name),
    );
    addTearDown(sets.dispose);

    await sets.put(_set('Docs', ['_site/']));

    expect(sets.value.map((set) => set.name), ['Web', 'Docs']);
  });

  test('a failed write throws and lists nothing new', () async {
    final sets = SkipRuleSetsController(
      initial: [
        _set('Web', ['*.log']),
      ],
      put: (_, {replacing}) => Future.error(StateError('disk full')),
      remove: (_) => Future.error(StateError('disk full')),
    );
    addTearDown(sets.dispose);
    var notified = 0;
    sets.addListener(() => notified++);

    await expectLater(
      sets.put(_set('Docs', ['_site/'])),
      throwsA(isA<StateError>()),
    );
    await expectLater(sets.remove('Web'), throwsA(isA<StateError>()));

    expect(sets.value, [
      _set('Web', ['*.log']),
    ]);
    expect(notified, 0);
  });
}
