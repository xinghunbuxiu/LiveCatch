import 'package:flutter_test/flutter_test.dart';
import 'package:livecatch_app/main.dart';

void main() {
  testWidgets('smoke page builds', (tester) async {
    await tester.pumpWidget(const LiveCatchApp());
    expect(find.text('LiveCatch'), findsOneWidget);
  });
}
