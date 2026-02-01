// ignore_for_file: use_build_context_synchronously

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../data/erp_database.dart';

class ThreadShadeMasterPage extends StatefulWidget {
  const ThreadShadeMasterPage({super.key});

  @override
  State<ThreadShadeMasterPage> createState() => _ThreadShadeMasterPageState();
}

class _ThreadShadeMasterPageState extends State<ThreadShadeMasterPage> {
  final shadeNoCtrl = TextEditingController();
  final qualityCtrl = TextEditingController();

  File? imageFile;
  List<Map<String, dynamic>> threadShades = [];

  int? editingId; // 👈 important

  @override
  void initState() {
    super.initState();
    _loadThreadShades();
  }

  Future<void> _loadThreadShades() async {
    final data = await ErpDatabase.instance.getThreadShadesFull();
    setState(() {
      threadShades = data;
    });
  }

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.gallery);
    if (picked != null) {
      setState(() {
        imageFile = File(picked.path);
      });
    }
  }

  // ================= EDIT =================
  void _editThreadShade(Map<String, dynamic> s) {
    setState(() {
      editingId = s['id'];
      shadeNoCtrl.text = s['shade_no'];
      qualityCtrl.text = s['quality'];
      imageFile = s['image_path'] != null ? File(s['image_path']) : null;
    });
  }

  // ================= SAVE / UPDATE =================
  Future<void> _saveThreadShade() async {
    if (shadeNoCtrl.text.trim().isEmpty || qualityCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Fill all fields')),
      );
      return;
    }

    final data = {
      'shade_no': shadeNoCtrl.text.trim(),
      'quality': qualityCtrl.text.trim(),
      'image_path': imageFile?.path,
    };

    if (editingId == null) {
      // ➕ ADD
      await ErpDatabase.instance.insertThreadShade(
        shadeNo: data['shade_no']!,
        quality: data['quality']!,
        imagePath: data['image_path'],
      );
    } else {
      // ✏️ UPDATE
      final db = await ErpDatabase.instance.database;
      await db.update(
        'thread_shades',
        data,
        where: 'id = ?',
        whereArgs: [editingId],
      );
    }

    _clearForm();
    await _loadThreadShades();

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
            editingId == null ? 'Thread shade added' : 'Thread shade updated'),
      ),
    );
  }

  // ================= DELETE =================
  Future<void> _deleteThreadShade(int id) async {
    await ErpDatabase.instance.deleteThreadShade(id);
    await _loadThreadShades();
  }

  // ================= CLEAR =================
  void _clearForm() {
    setState(() {
      editingId = null;
      shadeNoCtrl.clear();
      qualityCtrl.clear();
      imageFile = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Thread Shade Master')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: shadeNoCtrl,
              decoration: const InputDecoration(
                labelText: 'Thread Shade No',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: qualityCtrl,
              decoration: const InputDecoration(
                labelText: 'Quality',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                ElevatedButton.icon(
                  onPressed: _pickImage,
                  icon: const Icon(Icons.image),
                  label: const Text('Pick Image'),
                ),
                const SizedBox(width: 12),
                if (imageFile != null)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Image.file(
                      imageFile!,
                      width: 50,
                      height: 50,
                      fit: BoxFit.cover,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: _saveThreadShade,
                    child: Text(
                      editingId == null
                          ? 'ADD THREAD SHADE'
                          : 'UPDATE THREAD SHADE',
                    ),
                  ),
                ),
                if (editingId != null) ...[
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _clearForm,
                      child: const Text('CANCEL'),
                    ),
                  ),
                ],
              ],
            ),
            const Divider(height: 30),
            Expanded(
              child: threadShades.isEmpty
                  ? const Center(child: Text('No thread shades'))
                  : ListView.builder(
                      itemCount: threadShades.length,
                      itemBuilder: (_, i) {
                        final s = threadShades[i];
                        final imgPath = s['image_path'];

                        return Card(
                          child: ListTile(
                            leading:
                                imgPath != null && File(imgPath).existsSync()
                                    ? Image.file(
                                        File(imgPath),
                                        width: 50,
                                        height: 50,
                                        fit: BoxFit.cover,
                                      )
                                    : const Icon(Icons.image_not_supported),
                            title: Text(s['shade_no']),
                            subtitle: Text('Quality: ${s['quality']}'),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.edit,
                                      color: Colors.blue),
                                  onPressed: () => _editThreadShade(s),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.delete,
                                      color: Colors.red),
                                  onPressed: () =>
                                      _deleteThreadShade(s['id'] as int),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
