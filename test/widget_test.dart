// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wrapifyflutter/main.dart';
import 'package:wrapifyflutter/services/audio_player_service.dart';

void main() {
  testWidgets('App renders without crashing', (WidgetTester tester) async {
    // Create a player service for the test
    final playerService = AudioPlayerService();
    
    // Build our app and trigger a frame
    await tester.pumpWidget(MyApp(playerService: playerService));
    
    // Verify the app renders without throwing errors
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
