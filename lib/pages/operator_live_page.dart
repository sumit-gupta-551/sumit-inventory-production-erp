// ignore_for_file: use_build_context_synchronously

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../data/erp_database.dart';

class OperatorLivePage extends StatefulWidget {
  const OperatorLivePage({super.key});

  @override
  State<OperatorLivePage> createState() => _OperatorLivePageState();
}

class _OperatorLivePageState extends State<OperatorLivePage> {
  List<Map<String, dynamic>> allotments = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    allotments = await ErpDatabase.instance.getActiveAllotments();
    setState(() {});
  }

  Future<void> _updateStatus(
    Map<String, dynamic> a,
    String status, {
    String? reason,
  }) async {
    final log = {
      'program_no': a['program_no'],
      'machine_id': a['machine_id'],
      'status': status,
      'reason': reason,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };

    // LOCAL SQLITE
    await ErpDatabase.instance.logProgramActivity(log);
    await ErpDatabase.instance.updateAllotmentStatus(
      a['program_no'],
      status,
    );

    // FIRESTORE (REAL TIME)
    await FirebaseFirestore.instance
        .collection('program_activity_log')
        .add(log);

    await FirebaseFirestore.instance
        .collection('program_allotment')
        .where('programNo', isEqualTo: a['program_no'])
        .get()
        .then((snap) {
      for (final d in snap.docs) {
        d.reference.update({'status': status});
      }
    });

    _load();
  }

  Future<void> _pauseDialog(Map<String, dynamic> a) async {
    final reasons = await ErpDatabase.instance.getDelayReasons();
    String? selected;

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setStateSB) {
            return AlertDialog(
              title: const Text('Select Delay Reason'),
              content: DropdownButtonFormField<String>(
                value: selected,
                items: reasons
                    .map(
                      (r) => DropdownMenuItem<String>(
                        value: r['reason'],
                        child: Text(r['reason']),
                      ),
                    )
                    .toList(),
                onChanged: (v) {
                  setStateSB(() => selected = v);
                },
                decoration: const InputDecoration(labelText: 'Reason'),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: selected == null
                      ? null
                      : () {
                          Navigator.pop(context);
                          _updateStatus(
                            a,
                            'PAUSED',
                            reason: selected,
                          );
                        },
                  child: const Text('CONFIRM'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Operator Live')),
      body: allotments.isEmpty
          ? const Center(child: Text('No programs allotted'))
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: allotments.length,
              itemBuilder: (_, i) {
                final a = allotments[i];
                return Card(
                  child: ListTile(
                    title: Text(
                      'Program: ${a['program_no']}',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: Text(
                      'Machine: ${a['machine_code']} | Status: ${a['status']}',
                    ),
                    trailing: Wrap(
                      spacing: 8,
                      children: [
                        if (a['status'] == 'ALLOTTED')
                          IconButton(
                            icon: const Icon(Icons.play_arrow,
                                color: Colors.green),
                            onPressed: () => _updateStatus(a, 'RUNNING'),
                          ),
                        if (a['status'] == 'RUNNING')
                          IconButton(
                            icon: const Icon(Icons.pause, color: Colors.orange),
                            onPressed: () => _pauseDialog(a),
                          ),
                        if (a['status'] != 'COMPLETED')
                          IconButton(
                            icon: const Icon(Icons.check, color: Colors.blue),
                            onPressed: () => _updateStatus(a, 'COMPLETED'),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}
