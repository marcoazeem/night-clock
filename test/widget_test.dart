import 'package:flutter_test/flutter_test.dart';
import 'package:night_clock/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('clock renders stacked time digits', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const NightClockApp());
    await tester.pump();
    expect(find.byType(ClockScreen), findsOneWidget);
    // Let the one-shot hint timer fire so no timers are pending at teardown.
    await tester.pump(const Duration(seconds: 9));
  });
}
