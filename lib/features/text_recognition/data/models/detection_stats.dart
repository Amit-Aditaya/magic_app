class DetectionStats {
  final Map<String, List<double>> confidenceHistory = {};
  final Map<String, int> occurrenceCount = {};
  final DateTime startTime = DateTime.now();

  void addDetection(String text, double confidence) {
    confidenceHistory.putIfAbsent(text, () => []).add(confidence);
    occurrenceCount[text] = (occurrenceCount[text] ?? 0) + 1;
  }

  double getAverageConfidence(String text) {
    final confidences = confidenceHistory[text] ?? [];
    if (confidences.isEmpty) return 0.0;
    return confidences.reduce((a, b) => a + b) / confidences.length;
  }

  int getElapsedMs() {
    return DateTime.now().difference(startTime).inMilliseconds;
  }
}
