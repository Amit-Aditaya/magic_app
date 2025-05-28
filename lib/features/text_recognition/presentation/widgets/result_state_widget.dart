import 'package:flutter/material.dart';

class ResultStateWidget extends StatelessWidget {
  final String detectedText;

  const ResultStateWidget({super.key, required this.detectedText});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(height: 16),
          const Text(
            'MAGIC REVEALED! ✨',
            style: TextStyle(
              color: Colors.yellow,
              fontSize: 14,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white10,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.yellow, width: 1),
            ),
            child: Text(
              detectedText,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.1,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}
