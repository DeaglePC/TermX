import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:termx/core/models/host_config.dart';
import 'package:termx/core/models/terminal_workspace.dart';
import 'package:flutter/widgets.dart';
import 'package:termx/core/ssh/ssh_session_controller.dart';

Future<void> waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for local PowerShell');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  test(
    'Split PowerShell panes execute in separate processes and keep variables isolated',
    () async {
      final workspace = TerminalWorkspace();
      addTearDown(workspace.dispose);
      const host = HostConfig(
        id: 'split-test',
        name: 'PowerShell',
        host: 'localhost',
        authMethod: AuthMethod.localShell,
      );
      final left = workspace.open(host);
      final tab = workspace.activeTab!;
      final right = workspace.split(tab, left.id, Axis.horizontal);
      await Future.wait([
        left.session.connect(null),
        right.session.connect(null),
      ]);
      await waitFor(
        () =>
            left.session.terminal.buffer.getText().contains('PS ') &&
            right.session.terminal.buffer.getText().contains('PS '),
      );
      left.session.sendRawInput(
        '\$termxPane = 101; Write-Output (\'LEFT=\' + \$termxPane)\r',
      );
      right.session.sendRawInput(
        '\$termxPane = 202; Write-Output (\'RIGHT=\' + \$termxPane)\r',
      );
      await waitFor(
        () =>
            left.session.terminal.buffer.getText().contains('LEFT=101') &&
            right.session.terminal.buffer.getText().contains('RIGHT=202'),
      );
      left.session.sendRawInput(
        'Write-Output (\'UNCHANGED=\' + \$termxPane)\r',
      );
      await waitFor(
        () => left.session.terminal.buffer.getText().contains('UNCHANGED=101'),
      );
      expect(
        left.session.terminal.buffer.getText(),
        isNot(contains('RIGHT=202')),
      );
      workspace.closePane(tab, right.id);
      expect(right.disposed, isTrue);
      expect(workspace.activePane, left);
      left.session.sendRawInput('Write-Output (\'STILL\' + \'_ALIVE\')\r');
      await waitFor(
        () => left.session.terminal.buffer.getText().contains('STILL_ALIVE'),
      );
    },
    skip: !Platform.isWindows,
  );

  test(
    'Local PowerShell executes real commands, resizes, interrupts and exits',
    () async {
      final session = SshSessionController(
        sessionId: 'local-test',
        host: const HostConfig(
          id: 'local',
          name: '本地 PowerShell',
          host: 'localhost',
          authMethod: AuthMethod.localShell,
        ),
      );
      addTearDown(session.dispose);
      await session.connect(null);
      expect(
        session.state,
        SessionConnectionState.connected,
        reason: session.errorMessage,
      );
      expect(session.isDemoMode, isFalse);
      await waitFor(() => session.terminal.buffer.getText().contains('PS '));

      // A variable persists between commands in the same real shell process.
      session.sendRawInput('\$termxValue = 6 * 7\r');
      session.terminal.onOutput!(
        'Write-Output (\'RESULT=\' + \$termxValue); Write-Output ([char]0x4e2d)\r',
      );
      await waitFor(
        () => session.terminal.buffer.getText().contains('RESULT=42'),
      );
      await waitFor(() => session.terminal.buffer.getText().contains('中'));

      session.terminal.resize(100, 30);
      session.sendRawInput('Start-Sleep -Seconds 30\r');
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final promptPattern = RegExp(r'PS [^\n]*>');
      final promptCount = promptPattern
          .allMatches(session.terminal.buffer.getText())
          .length;
      session.sendRawInput('\x03');
      await waitFor(
        () =>
            promptPattern.allMatches(session.terminal.buffer.getText()).length >
            promptCount,
      );
      session.sendRawInput('Write-Output (\'AFTER\' + \'_INTERRUPT\')\r');
      await waitFor(
        () => session.terminal.buffer.getText().contains('AFTER_INTERRUPT'),
      );

      await expectLater(
        session.listDirectory('/root'),
        throwsA(isA<UnsupportedError>()),
      );
      session.sendRawInput('exit\r');
      await waitFor(() => session.state == SessionConnectionState.disconnected);
      session.sendRawInput('ignored after exit');
      expect(session.terminal.buffer.getText(), isNot(contains('[Executed]')));
    },
    skip: !Platform.isWindows,
  );
}
