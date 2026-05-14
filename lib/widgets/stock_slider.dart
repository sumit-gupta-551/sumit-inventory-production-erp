import 'package:flutter/material.dart';

class StockSlider extends StatelessWidget {
  const StockSlider({super.key});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 120,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: const [
          StockCard(
            title: 'Total Stock',
            value: '1,250',
            colors: [Color(0xFF1565C0), Color(0xFF0066FF)],
          ),
          StockCard(
            title: 'Low Stock',
            value: '12',
            colors: [Color(0xFFFF1744), Color(0xFFFF5252)],
          ),
          StockCard(
            title: 'Today In',
            value: '320',
            colors: [Color(0xFF00E676), Color(0xFF1DE9B6)],
          ),
          StockCard(
            title: 'Today Out',
            value: '180',
            colors: [Color(0xFFFF9100), Color(0xFFFF6D00)],
          ),
        ],
      ),
    );
  }
}

class StockCard extends StatelessWidget {
  final String title;
  final String value;
  final List<Color> colors;

  const StockCard({
    super.key,
    required this.title,
    required this.value,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 170,
      margin: const EdgeInsets.only(right: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          colors: colors,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [
          BoxShadow(
            color: colors.first.withValues(alpha: 0.65),
            blurRadius: 26,
            spreadRadius: 1,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
          const Spacer(),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 26,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}

