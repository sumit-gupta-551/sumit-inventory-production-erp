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
  final shadeCtrl = TextEditingController();
  final qualityCtrl = TextEditingController();

  File? imageFile;
  List<Map<String, dynamic>> shades = [];

  @override
  void initState() {
    super.initState();
    _loadShades();
  }

  Future<void> _loadShades() async {
    shades = await ErpDatabase.instance.getThreadShadesFull();
    setState(() {});
  }

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final img = await picker.pickImage(source: ImageSource.gallery);
    if (img != null) {
      setState(() {
        imageFile = File(img.path);
      });
    }
  }

  Future<void> _saveShade() async {
    if (shadeCtrl.text.trim().isEmpty || qualityCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Fill all fields')),
      );
      return;
    }

    await ErpDatabase.instance.insertThreadShade(
      shadeNo: shadeCtrl.text.trim(),
      quality: qualityCtrl.text.trim(),
      imagePath: imageFile?.path,
    );

    shadeCtrl.clear();
    qualityCtrl.clear();
    imageFile = null;

    await _loadShades();

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Thread shade added successfully')),
    );
  }

  Future<void> _deleteShade(int id) async {
    await ErpDatabase.instance.deleteThreadShade(id);
    await _loadShades();
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
              controller: shadeCtrl,
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
                const SizedBox(width: 10),
                if (imageFile != null) const Text('Image selected'),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 45,
              child: ElevatedButton(
                onPressed: _saveShade,
                child: const Text('ADD THREAD SHADE'),
              ),
            ),
            const Divider(height: 30),
            Expanded(
              child: shades.isEmpty
                  ? const Center(child: Text('No thread shades'))
                  : ListView.builder(
                      itemCount: shades.length,
                      itemBuilder: (_, i) {
                        final s = shades[i];
                        return Card(
                          child: ListTile(
                            leading: s['image_path'] != null
                                ? Image.file(
                                    File(s['image_path']),
                                    width: 50,
                                    height: 50,
                                    fit: BoxFit.cover,
                                  )
                                : const Icon(Icons.image),
                            title: Text(s['shade_no']),
                            subtitle: Text('Quality: ${s['quality']}'),
                            trailing: IconButton(
                              icon: const Icon(Icons.delete, color: Colors.red),
                              onPressed: () => _deleteShade(s['id']),
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
