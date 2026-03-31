// ignore_for_file: use_build_context_synchronously

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/erp_database.dart';

class ProgramPreviewPage extends StatefulWidget {
  final int programNo;
  final bool showSavedMsg;

  const ProgramPreviewPage({
    super.key,
    required this.programNo,
    this.showSavedMsg = false,
  });

  @override
  State<ProgramPreviewPage> createState() => _ProgramPreviewPageState();
}

class _ProgramPreviewPageState extends State<ProgramPreviewPage> {
  Map<String, dynamic>? program;
  List<Map<String, dynamic>> fabrics = [];
  List<Map<String, dynamic>> threads = [];

  @override
  void initState() {
    super.initState();
    _loadPreview();
  }

  Future<void> _loadPreview() async {
    final db = ErpDatabase.instance;

    program = await db.getProgramByNo(widget.programNo);
    fabrics = await db.getProgramFabrics(widget.programNo);
    threads = await db.getProgramThreads(widget.programNo);

    if (mounted) {
      setState(() {});
      if (widget.showSavedMsg) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Program saved successfully'),
            backgroundColor: Colors.green,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (program == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Program Preview'),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit),
            onPressed: () {
              Navigator.pop(context); // back to edit
            },
          )
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            _section('Program Details', [
              _row('Program No', program!['program_no'].toString()),
              _row(
                'Date',
                DateFormat('dd-MM-yyyy').format(
                  DateTime.fromMillisecondsSinceEpoch(
                    program!['program_date'],
                  ),
                ),
              ),
              _row('Party', program!['party_name'] ?? '-'),
              _row('Card No', program!['card_no'] ?? '-'),
              _row('Design No', program!['design_no'] ?? '-'),
              _row('Designer', program!['designer'] ?? '-'),
            ]),
            _section('Fabric Planning', [
              if (fabrics.isEmpty)
                const Text('No fabric added')
              else
                ...fabrics.map(
                  (f) => ListTile(
                    dense: true,
                    title: Text(f['shade_no']),
                    trailing: Text('Qty: ${f['qty']}'),
                  ),
                ),
            ]),
            _section('Thread Shades', [
              if (threads.isEmpty)
                const Text('No thread shades added')
              else
                Wrap(
                  spacing: 8,
                  children: threads
                      .map(
                        (t) => Chip(label: Text(t['shade_no'])),
                      )
                      .toList(),
                ),
            ]),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 44,
              child: ElevatedButton(
                onPressed: () {
                  Navigator.pop(context); // Next program
                },
                child: const Text('NEXT PROGRAM'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------- HELPERS ----------------
  Widget _section(String title, List<Widget> children) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: Theme.of(context).cardColor,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      );

  Widget _row(String l, String v) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          children: [
            SizedBox(
              width: 100,
              child: Text(
                l,
                style: const TextStyle(fontWeight: FontWeight.w500),
              ),
            ),
            Expanded(child: Text(v)),
          ],
        ),
      );
}
