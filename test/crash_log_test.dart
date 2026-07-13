import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:slate/core/app_version.dart';
import 'package:slate/core/state/crash_log.dart';

/// Crash log contract: version-stamped entries, pre-init buffering, and the
/// size-capped rotation that keeps the log from growing forever.
void main() {
  late Directory temp;

  setUpAll(() {
    temp = Directory.systemTemp.createTempSync('slate_logs');
  });

  test('records buffered before init are flushed with version + stack', () {
    CrashLog.record(StateError('early boom'), StackTrace.current);
    CrashLog.init(Directory('${temp.path}\\logs'));

    final f = File('${temp.path}\\logs\\slate_log.txt');
    expect(f.existsSync(), isTrue);
    final body = f.readAsStringSync();
    expect(body, contains('Slate v$kAppVersion'));
    expect(body, contains('early boom'));
    expect(body, contains('crash_log_test'), reason: 'stack trace present');
  });

  test('oversized log rotates into .1 instead of growing forever', () {
    final dir = Directory('${temp.path}\\logs');
    final f = File('${dir.path}\\slate_log.txt');
    f.writeAsStringSync('x' * (600 * 1024)); // beyond the 512KB cap

    CrashLog.record(ArgumentError('after rotation'), StackTrace.current);

    expect(File('${dir.path}\\slate_log.1.txt').existsSync(), isTrue);
    final fresh = f.readAsStringSync();
    expect(fresh.length, lessThan(100 * 1024), reason: 'fresh file started');
    expect(fresh, contains('after rotation'));
  });
}
