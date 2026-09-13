import 'package:flutter_test/flutter_test.dart';

import 'package:voxa/main.dart';

void main() {
  testWidgets('home screen shows the record button', (WidgetTester tester) async {
    await tester.pumpWidget(const VoxaApp());
    await tester.pump();

    expect(find.text('Записать'), findsOneWidget);
  });
}
