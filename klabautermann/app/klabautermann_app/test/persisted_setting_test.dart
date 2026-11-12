// The shared persisted setting: a change applies and notifies before it
// is saved, a failed save throws the setting's own exception and keeps
// the change, and the same value picked again retries the save.
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/persisted_setting.dart';

final class _NotSaved implements Exception {
  const _NotSaved(this.message);

  final String message;
}

final class _Setting extends PersistedSetting<int> {
  _Setting(super.value, this.saves);

  /// The values saved; each true entry in [failures] fails a save.
  final List<int> saves;
  final List<bool> failures = [];

  Future<void> set(int next) => change(next);

  @override
  Future<void>? save(int value) async {
    if (failures.isNotEmpty && failures.removeAt(0)) {
      throw const FormatException('disk full');
    }
    saves.add(value);
  }

  @override
  Exception notSaved(Object error) => _NotSaved('not saved: $error');
}

void main() {
  test('applies and notifies before it saves', () async {
    final saves = <int>[];
    final setting = _Setting(1, saves);
    addTearDown(setting.dispose);
    // Listeners see the change before the save starts.
    setting.addListener(() => expect(saves, isEmpty));

    await setting.set(2);
    expect(setting.value, 2);
    expect(saves, [2]);
  });

  test('the value in force and saved is a no-op', () async {
    final saves = <int>[];
    final setting = _Setting(1, saves);
    addTearDown(setting.dispose);
    var notified = 0;
    setting.addListener(() => notified++);

    await setting.set(1);
    expect(saves, isEmpty);
    expect(notified, 0);
  });

  test('a failed save keeps the change, throws, and retries', () async {
    final saves = <int>[];
    final setting = _Setting(1, saves)..failures.add(true);
    addTearDown(setting.dispose);
    var notified = 0;
    setting.addListener(() => notified++);

    await expectLater(
      setting.set(2),
      throwsA(
        isA<_NotSaved>().having(
          (error) => error.message,
          'message',
          'not saved: FormatException: disk full',
        ),
      ),
    );
    expect(setting.value, 2);
    expect(saves, isEmpty);

    // Picking it again saves without notifying a second time.
    await setting.set(2);
    expect(saves, [2]);
    expect(notified, 1);
  });

  test('a setting with nowhere to save holds the value', () async {
    final setting = _Unsaved(1);
    addTearDown(setting.dispose);
    await setting.set(3);
    expect(setting.value, 3);
  });
}

final class _Unsaved extends PersistedSetting<int> {
  _Unsaved(super.value);

  Future<void> set(int next) => change(next);

  @override
  Future<void>? save(int value) => null;

  @override
  Exception notSaved(Object error) => _NotSaved('$error');
}
