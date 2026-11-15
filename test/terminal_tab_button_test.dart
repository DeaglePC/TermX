import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termx/ui/widgets/terminal_tab_button.dart';

void main() {
  testWidgets('Tab activates on pointer down without waiting for double tap', (
    tester,
  ) async {
    var activations = 0;
    var renames = 0;
    var closes = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              height: 40,
              child: TerminalTabButton(
                active: false,
                accent: Colors.blue,
                title: 'Terminal',
                status: const Icon(Icons.circle, size: 8),
                dragHandle: const SizedBox(width: 10),
                onActivate: () => activations++,
                onRename: () => renames++,
                onClose: () => closes++,
                onMenu: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Terminal')),
    );
    // No pump, release, or double-tap timeout has elapsed.
    expect(activations, 1);
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('Terminal'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(renames, 1);
    final beforeClose = activations;
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump(const Duration(milliseconds: 400));
    expect(closes, 1);
    expect(activations, beforeClose);
    await tester.pumpWidget(const SizedBox());
  });
}
