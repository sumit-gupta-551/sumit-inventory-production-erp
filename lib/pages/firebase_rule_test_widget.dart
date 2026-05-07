import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

class FirebaseRuleTestWidget extends StatefulWidget {
  @override
  _FirebaseRuleTestWidgetState createState() => _FirebaseRuleTestWidgetState();
}

class _FirebaseRuleTestWidgetState extends State<FirebaseRuleTestWidget> {
  String _result = 'Not tested yet';

  Future<void> _testWrite() async {
    try {
      // Sign in anonymously (or use your existing auth method)
      await FirebaseAuth.instance.signInAnonymously();

      DatabaseReference ref = FirebaseDatabase.instance.ref('test_node');
      await ref.set(
          {'test': 'value', 'timestamp': DateTime.now().toIso8601String()});
      setState(() {
        _result = 'Write succeeded!';
      });
    } catch (e) {
      setState(() {
        _result = 'Write failed: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ElevatedButton(
          onPressed: _testWrite,
          child: Text('Test Firebase Write'),
        ),
        SizedBox(height: 8),
        Text(_result, style: TextStyle(fontSize: 12)),
      ],
    );
  }
}
