import 'package:flutter/material.dart';
import '../data/erp_database.dart';
import '../models/party.dart';

/// =======================
/// DASHBOARD COLOR SYSTEM
/// =======================
class AppColors {
  static const bg = Color(0xFF0D0221);
  static const card = Color(0xFF120230);
  static const shadow = Color(0x40000000);

  static const primary = Color(0xFF00F5FF);
  static const success = Color(0xFF51CF66);
  static const pink = Color(0xFFFF00E5);

  static const textDark = Color(0xFFF8FAFC);
  static const textLight = Color(0xFF94A3B8);
}

/// =======================
/// PARTY FORM PAGE
/// =======================
class PartyFormPage extends StatefulWidget {
  final Party? party;

  const PartyFormPage({super.key, this.party});

  @override
  State<PartyFormPage> createState() => _PartyFormPageState();
}

class _PartyFormPageState extends State<PartyFormPage> {
  final nameCtrl = TextEditingController();
  final addressCtrl = TextEditingController();
  final mobileCtrl = TextEditingController();
  String _selectedPartyType = 'Sales';

  @override
  void initState() {
    super.initState();

    // EDIT MODE
    if (widget.party != null) {
      nameCtrl.text = widget.party!.name;
      addressCtrl.text = widget.party!.address;
      mobileCtrl.text = widget.party!.mobile;
      _selectedPartyType = widget.party!.partyType;
    }
  }

  Future<void> _saveParty() async {
    if (nameCtrl.text.trim().isEmpty ||
        addressCtrl.text.trim().isEmpty ||
        mobileCtrl.text.trim().isEmpty) {
      _msg('All fields are required');
      return;
    }

    if (widget.party == null) {
      // ADD
      await ErpDatabase.instance.insertParty(
        Party(
          name: nameCtrl.text.trim(),
          address: addressCtrl.text.trim(),
          mobile: mobileCtrl.text.trim(),
          partyType: _selectedPartyType,
        ),
      );
    } else {
      // UPDATE
      await ErpDatabase.instance.updateParty(
        widget.party!.copyWith(
          name: nameCtrl.text.trim(),
          address: addressCtrl.text.trim(),
          mobile: mobileCtrl.text.trim(),
          partyType: _selectedPartyType,
        ),
      );
    }

    if (!mounted) return;

    Navigator.pop(context);
  }

  void _msg(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        elevation: 0,
        backgroundColor: AppColors.bg,
        centerTitle: true,
        title: Text(
          widget.party == null ? 'Add Party' : 'Edit Party',
          style: const TextStyle(
            color: AppColors.textDark,
            fontWeight: FontWeight.w700,
          ),
        ),
        iconTheme: const IconThemeData(color: AppColors.textDark),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Container(
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(24),
            boxShadow: const [
              BoxShadow(
                color: AppColors.shadow,
                blurRadius: 20,
                offset: Offset(0, 12),
              ),
            ],
          ),
          child: Column(
            children: [
              // Party Type Dropdown
              Padding(
                padding: const EdgeInsets.only(bottom: 18),
                child: DropdownButtonFormField<String>(
                  value: _selectedPartyType,
                  decoration: InputDecoration(
                    labelText: 'Party Type',
                    labelStyle: const TextStyle(color: AppColors.textLight),
                    prefixIcon:
                        const Icon(Icons.category, color: AppColors.primary),
                    filled: true,
                    fillColor: AppColors.bg,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 14),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(18),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  items: const [
                    DropdownMenuItem(
                        value: 'Sales', child: Text('Sales Party')),
                    DropdownMenuItem(
                        value: 'Purchase', child: Text('Purchase Party')),
                  ],
                  onChanged: (val) {
                    if (val != null) setState(() => _selectedPartyType = val);
                  },
                ),
              ),
              _field(
                nameCtrl,
                'Party Name',
                Icons.business,
                AppColors.primary,
              ),
              _field(
                addressCtrl,
                'Address',
                Icons.location_on,
                AppColors.pink,
              ),
              _field(
                mobileCtrl,
                'Mobile No',
                Icons.phone,
                AppColors.success,
                keyboard: TextInputType.phone,
              ),
              const SizedBox(height: 30),
              SizedBox(
                width: double.infinity,
                height: 54,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    elevation: 4,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                  ),
                  onPressed: _saveParty,
                  child: const Text(
                    'SAVE PARTY',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// =======================
  /// DASHBOARD STYLE FIELD
  /// =======================
  Widget _field(
    TextEditingController controller,
    String label,
    IconData icon,
    Color iconColor, {
    TextInputType keyboard = TextInputType.text,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: TextField(
        controller: controller,
        keyboardType: keyboard,
        decoration: InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(color: AppColors.textLight),
          prefixIcon: Icon(icon, color: iconColor),
          filled: true,
          fillColor: AppColors.bg,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    nameCtrl.dispose();
    addressCtrl.dispose();
    mobileCtrl.dispose();
    super.dispose();
  }
}
