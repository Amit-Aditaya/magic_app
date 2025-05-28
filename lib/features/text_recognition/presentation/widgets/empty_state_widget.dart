import 'package:flutter/material.dart';

class EmptyStateWidget extends StatelessWidget {
  const EmptyStateWidget({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(height: 12),
          Text(
            'Ready for Magic! 🎩',
            style: TextStyle(
                color: Colors.white54,
                fontSize: 16,
                fontWeight: FontWeight.bold),
          ),
          SizedBox(height: 4),
          Text(
            'Place paper with text over camera',
            style: TextStyle(color: Colors.white38, fontSize: 14),
          ),
        ],
      ),
    );
  }
}
