import 'package:flutter_test/flutter_test.dart';
import 'package:profile_finder/main.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const RoofProfileFinderApp());
  });
}
