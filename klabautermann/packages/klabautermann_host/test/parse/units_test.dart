// `units` parser tests (03 §6.4, §7.5): the JSON shape of systemd 246+
// and the `--plain --no-legend` text table below it, plus tolerance for
// legend lines and non-string JSON fields.
import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

const _ctx = ParseContext.standard;

void main() {
  test('JSON rows carry unit, load, active, sub and description', () {
    final raw = [
      '== units_json ==',
      '[{"unit":"cron.service","load":"loaded","active":"active",'
          '"sub":"running","description":"Regular background daemon"},'
          '{"unit":"foo.service","load":"loaded","active":"failed",'
          '"sub":"failed","description":"A thing"}]',
      '== failed_json ==',
      '[{"unit":"foo.service","load":"loaded","active":"failed",'
          '"sub":"failed","description":"A thing"}]',
    ].join('\n');

    final r = parseUnits(raw, _ctx);
    expect(r.value.format, UnitListFormat.json);
    expect(r.value.units, hasLength(2));
    expect(r.value.units.first.unit, 'cron.service');
    expect(r.value.units.first.description, 'Regular background daemon');
    expect(r.value.failed.single.unit, 'foo.service');
    expect(r.value.failed.single.active, 'failed');
  });

  test('non-string JSON fields are tolerated, not thrown on', () {
    final raw = [
      '== units_json ==',
      '[{"unit":"x.service","load":5,"active":true,"sub":null}]',
    ].join('\n');
    final r = parseUnits(raw, _ctx);
    expect(r.value.units.single.load, '5');
    expect(r.value.units.single.active, 'true');
    expect(r.value.units.single.sub, isNull);
  });

  test('text rows slice UNIT LOAD ACTIVE SUB and the description', () {
    final raw = [
      '== units_text ==',
      'UNIT LOAD ACTIVE SUB DESCRIPTION',
      'cron.service loaded active running Regular background daemon',
      'foo.service loaded failed failed A thing with spaces',
      '3 loaded units listed.',
      '== failed_text ==',
      'foo.service loaded failed failed A thing with spaces',
    ].join('\n');

    final r = parseUnits(raw, _ctx);
    expect(r.value.format, UnitListFormat.text);
    expect(r.value.units, hasLength(2));
    expect(r.value.units.last.unit, 'foo.service');
    expect(r.value.units.last.description, 'A thing with spaces');
    expect(r.value.failed.single.unit, 'foo.service');
  });

  test('an empty payload yields no units and a warning', () {
    final r = parseUnits('', _ctx);
    expect(r.value.format, UnitListFormat.none);
    expect(r.value.units, isEmpty);
    expect(r.warnings, isNotEmpty);
  });
}
