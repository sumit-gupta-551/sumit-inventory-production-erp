// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';
import 'package:sssj/pages/dashboard_page.dart';

void main() {
  test('DashboardPage can be created', () {
    const page = DashboardPage();
    expect(page, isNotNull);
  });
}
