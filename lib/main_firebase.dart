import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'pages/dashboard_page.dart';
// import 'firebase_options.dart'; // Uncomment if you use FlutterFire CLI

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(); // Add options if using firebase_options.dart
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'ERP Inventory',
      home: DashboardPage(),
    );
  }
}
