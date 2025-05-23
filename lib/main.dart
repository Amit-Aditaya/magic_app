import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'dart:async';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final cameras = await availableCameras();

  // Specifically select the back camera
  final backCamera = cameras.firstWhere(
    (camera) => camera.lensDirection == CameraLensDirection.back,
    orElse: () => cameras.first,
  );

  runApp(MyApp(camera: backCamera));
}

class MyApp extends StatelessWidget {
  final CameraDescription camera;

  const MyApp({super.key, required this.camera});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: TextRecognitionScreen(camera: camera),
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
    );
  }
}

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

class TextRecognitionScreen extends StatefulWidget {
  final CameraDescription camera;

  const TextRecognitionScreen({super.key, required this.camera});

  @override
  _TextRecognitionScreenState createState() => _TextRecognitionScreenState();
}

class _TextRecognitionScreenState extends State<TextRecognitionScreen>
    with WidgetsBindingObserver {
  late CameraController _controller;
  late Future<void> _initializeControllerFuture;
  bool _isDetecting = false;
  String? _finalDetectedText;
  final TextRecognizer _textRecognizer =
      TextRecognizer(script: TextRecognitionScript.latin);
  bool _isProcessing = false;
  String _debugInfo = "";
  Timer? _detectionTimer;
  Timer? _emergencyTimer;

  // Adaptive detection system
  DetectionStats _stats = DetectionStats();
  bool _hasTriggeredFlash = false;
  bool _hasIncreasedSensitivity = false;

  // Adaptive thresholds
  double _currentConfidenceThreshold = 0.75; // Start high
  int _currentOccurrenceThreshold = 3; // Start high

  // Emergency fallback
  String? _bestCandidateText;
  double _bestCandidateScore = 0.0;

  // Auto-enhancement flags
  bool _autoFlashEnabled = false;
  double _currentZoomLevel = 1.0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeCamera();
  }

  void _initializeCamera() {
    _controller = CameraController(
      widget.camera,
      ResolutionPreset.veryHigh,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );

    _initializeControllerFuture = _controller.initialize().then((_) {
      if (mounted) {
        setState(() {});
        _optimizeCameraSettings();
      }
    }).catchError((error) {
      setState(() {
        _debugInfo = 'Error initializing camera: $error';
      });
      print('Error initializing camera: $error');
    });
  }

  Future<void> _optimizeCameraSettings() async {
    try {
      await _controller.setFocusMode(FocusMode.auto);
      await _controller.setExposureMode(ExposureMode.auto);
      await _controller.setFlashMode(FlashMode.off);

      // Start with slight zoom for better text clarity
      final double maxZoom = await _controller.getMaxZoomLevel();
      if (maxZoom > 1.2) {
        _currentZoomLevel = 1.2;
        await _controller.setZoomLevel(_currentZoomLevel);
      }

      setState(() {
        _debugInfo = "Camera optimized - ready for magic! 🎩";
      });
    } catch (e) {
      print('Error optimizing camera: $e');
    }
  }

  @override
  void dispose() {
    stopDetection();
    _detectionTimer?.cancel();
    _emergencyTimer?.cancel();
    _controller.dispose();
    _textRecognizer.close();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_controller.value.isInitialized) return;

    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      stopDetection();
    } else if (state == AppLifecycleState.resumed) {
      if (_isDetecting) {
        startDetection();
      }
    }
  }

  void startDetection() async {
    try {
      await _initializeControllerFuture;
      if (_controller.value.isStreamingImages) return;

      // Reset all state
      _resetDetectionState();

      // Set up timers for adaptive behavior
      _setupAdaptiveTimers();

      setState(() {
        _debugInfo = "🔍 Scanning for text... (Hold steady for 2-3 seconds)";
      });

      await _controller.startImageStream((CameraImage image) async {
        if (_isProcessing) return;

        _isProcessing = true;
        _isDetecting = true;

        try {
          // Enhanced auto-focus for clarity
          await _smartAutoFocus();

          final inputImage = await _convertCameraImage(image);
          final RecognizedText recognizedText =
              await _textRecognizer.processImage(inputImage);

          _processRecognitionResults(recognizedText);
        } catch (e) {
          print('Detection error: $e');
        } finally {
          // Faster processing for quicker detection
          await Future.delayed(const Duration(milliseconds: 150));
          _isProcessing = false;
        }
      });
    } catch (e) {
      setState(() {
        _debugInfo = "Error starting detection: $e";
      });
      _isDetecting = false;
    }
  }

  void _resetDetectionState() {
    _stats = DetectionStats();
    _hasTriggeredFlash = false;
    _hasIncreasedSensitivity = false;
    _currentConfidenceThreshold = 0.75;
    _currentOccurrenceThreshold = 3;
    _bestCandidateText = null;
    _bestCandidateScore = 0.0;
    _finalDetectedText = null;
  }

  void _setupAdaptiveTimers() {
    // Main evaluation timer (faster)
    _detectionTimer?.cancel();
    _detectionTimer = Timer.periodic(
      const Duration(milliseconds: 300),
      (timer) => _evaluateAdaptiveDetection(),
    );

    // Step 1: Lower thresholds after 1.5 seconds
    Timer(const Duration(milliseconds: 1500), () {
      if (_isDetecting && _finalDetectedText == null) {
        _currentConfidenceThreshold = 0.65;
        _currentOccurrenceThreshold = 2;
        setState(() {
          _debugInfo = "📸 Enhancing sensitivity...";
        });
        _hasIncreasedSensitivity = true;
      }
    });

    // Step 2: Enable auto-flash after 2.5 seconds
    Timer(const Duration(milliseconds: 2500), () {
      if (_isDetecting && _finalDetectedText == null) {
        // _enableAutoFlash();
      }
    });

    // Step 3: Emergency fallback after 4 seconds
    _emergencyTimer = Timer(const Duration(milliseconds: 4000), () {
      if (_isDetecting && _finalDetectedText == null) {
        _triggerEmergencyFallback();
      }
    });
  }

  Future<void> _smartAutoFocus() async {
    // More aggressive focus for text
    try {
      await _controller.setFocusPoint(const Offset(0.5, 0.5));
      await _controller.setExposurePoint(const Offset(0.5, 0.5));
    } catch (e) {
      // Ignore focus errors
    }
  }

  Future<void> _enableAutoFlash() async {
    if (_hasTriggeredFlash) return;

    try {
      setState(() {
        _debugInfo = "💡 Auto-flash enabled for better detection";
      });

      await _controller.setFlashMode(FlashMode.torch);
      _hasTriggeredFlash = true;
      _autoFlashEnabled = true;

      // Flash for 1 second then turn off
      Timer(const Duration(milliseconds: 1000), () async {
        try {
          await _controller.setFlashMode(FlashMode.off);
          _autoFlashEnabled = false;
        } catch (e) {
          print('Error turning off flash: $e');
        }
      });
    } catch (e) {
      print('Error enabling flash: $e');
    }
  }

  void _triggerEmergencyFallback() {
    if (_bestCandidateText != null && _bestCandidateScore > 0.3) {
      setState(() {
        _finalDetectedText = _bestCandidateText;
        _debugInfo = "✅ DETECTED (Emergency): '$_bestCandidateText'";
      });

      HapticFeedback.heavyImpact();
      stopDetection();
    } else {
      setState(() {
        _debugInfo = "⚠️ Move paper closer or improve lighting";
      });
    }
  }

  Future<InputImage> _convertCameraImage(CameraImage image) async {
    final WriteBuffer allBytes = WriteBuffer();
    for (final Plane plane in image.planes) {
      allBytes.putUint8List(plane.bytes);
    }
    final bytes = allBytes.done().buffer.asUint8List();

    final Size imageSize =
        Size(image.width.toDouble(), image.height.toDouble());
    final imageRotation = _getRotationValue(widget.camera.sensorOrientation);
    final inputImageFormat =
        InputImageFormatValue.fromRawValue(image.format.raw) ??
            InputImageFormat.yuv420;

    return InputImage.fromBytes(
      bytes: bytes,
      metadata: InputImageMetadata(
        size: imageSize,
        rotation: imageRotation,
        format: inputImageFormat,
        bytesPerRow: image.planes[0].bytesPerRow,
      ),
    );
  }

  void _processRecognitionResults(RecognizedText recognizedText) {
    for (final block in recognizedText.blocks) {
      double blockConfidence = _calculateEnhancedConfidence(block);
      String cleanText = _cleanText(block.text);

      if (cleanText.isNotEmpty && cleanText.length >= 2) {
        _stats.addDetection(cleanText, blockConfidence);

        // Always track the best candidate for emergency fallback
        double candidateScore = blockConfidence * (cleanText.length / 10.0);
        if (candidateScore > _bestCandidateScore) {
          _bestCandidateScore = candidateScore;
          _bestCandidateText = cleanText;
        }
      }
    }
  }

  double _calculateEnhancedConfidence(TextBlock block) {
    double confidence = 0.0;
    int elementCount = 0;

    for (final line in block.lines) {
      for (final element in line.elements) {
        confidence += element.confidence ?? 0.0;
        elementCount++;
      }
    }

    if (elementCount == 0) return 0.0;

    double avgConfidence = confidence / elementCount;

    // Enhanced scoring with adaptive boosts
    if (block.text.length > 3) avgConfidence *= 1.15;
    if (block.text.length > 6) avgConfidence *= 1.1;

    // Boost confidence if we've lowered thresholds (harder conditions)
    if (_hasIncreasedSensitivity) avgConfidence *= 1.1;
    if (_hasTriggeredFlash) avgConfidence *= 1.05;

    return avgConfidence.clamp(0.0, 1.0);
  }

  String _cleanText(String text) {
    return text
        .replaceAll(RegExp(r'[^\w\s]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .toUpperCase();
  }

  void _evaluateAdaptiveDetection() {
    if (_stats.occurrenceCount.isEmpty) return;

    String? bestCandidate;
    double bestScore = 0.0;

    for (final entry in _stats.occurrenceCount.entries) {
      final String text = entry.key;
      final int occurrences = entry.value;
      final double avgConfidence = _stats.getAverageConfidence(text);

      // Adaptive scoring based on current thresholds
      double score = (occurrences / _currentOccurrenceThreshold) * 0.6 +
          (avgConfidence / _currentConfidenceThreshold) * 0.4;

      // Bonus for longer text (more meaningful)
      if (text.length > 5) score *= 1.2;

      // Time pressure bonus (after 2 seconds, be more lenient)
      int elapsedMs = _stats.getElapsedMs();
      if (elapsedMs > 2000) score *= 1.3;
      if (elapsedMs > 3000) score *= 1.5;

      if (occurrences >= _currentOccurrenceThreshold &&
          avgConfidence >= _currentConfidenceThreshold &&
          score > bestScore) {
        bestScore = score;
        bestCandidate = text;
      }
    }

    // Check for quick wins (very high confidence single detection)
    if (bestCandidate == null) {
      for (final entry in _stats.occurrenceCount.entries) {
        final String text = entry.key;
        final double avgConfidence = _stats.getAverageConfidence(text);

        // Quick win: very high confidence, even with single occurrence
        if (avgConfidence > 0.9 && text.length >= 3) {
          bestCandidate = text;
          bestScore = 1.0;
          break;
        }
      }
    }

    if (bestCandidate != null && bestCandidate != _finalDetectedText) {
      setState(() {
        _finalDetectedText = bestCandidate;
        _debugInfo =
            "✅ FINAL TEXT: '$bestCandidate' (Score: ${bestScore.toStringAsFixed(2)}, Time: ${_stats.getElapsedMs()}ms)";
      });

      HapticFeedback.heavyImpact();

      // Auto-stop after successful detection
      Timer(const Duration(milliseconds: 300), () {
        if (mounted) stopDetection();
      });
    }
  }

  InputImageRotation _getRotationValue(int sensorOrientation) {
    final deviceOrientation = MediaQuery.of(context).orientation;
    int rotationCompensation = 0;

    if (deviceOrientation == Orientation.portrait) {
      rotationCompensation = sensorOrientation;
    } else if (deviceOrientation == Orientation.landscape) {
      if (sensorOrientation == 90) {
        rotationCompensation = 0;
      } else if (sensorOrientation == 270) {
        rotationCompensation = 180;
      }
    }

    switch (rotationCompensation) {
      case 0:
        return InputImageRotation.rotation0deg;
      case 90:
        return InputImageRotation.rotation90deg;
      case 180:
        return InputImageRotation.rotation180deg;
      case 270:
        return InputImageRotation.rotation270deg;
      default:
        return InputImageRotation.rotation0deg;
    }
  }

  void stopDetection() {
    _isDetecting = false;
    _detectionTimer?.cancel();
    _emergencyTimer?.cancel();

    // Turn off flash if enabled
    if (_autoFlashEnabled) {
      try {
        _controller.setFlashMode(FlashMode.off);
        _autoFlashEnabled = false;
      } catch (e) {
        print('Error turning off flash: $e');
      }
    }

    if (_controller.value.isInitialized &&
        _controller.value.isStreamingImages) {
      try {
        _controller.stopImageStream();
      } catch (e) {
        print('Error stopping image stream: $e');
      }
    }
    setState(() {});
  }

  void clearDetectedText() {
    setState(() {
      _finalDetectedText = null;
      _debugInfo = "Ready for next detection 🎩";
    });
  }

  // Enhanced single capture with burst mode
  void enhancedCapture() async {
    try {
      await _initializeControllerFuture;

      setState(() {
        _debugInfo = "📸 Enhanced capture in progress...";
      });

      // Multiple rapid captures for best result
      List<String> capturedTexts = [];

      for (int i = 0; i < 3; i++) {
        // Auto-focus before each capture
        await _controller.setFocusPoint(const Offset(0.5, 0.5));
        await Future.delayed(const Duration(milliseconds: 100));

        final XFile image = await _controller.takePicture();
        final InputImage inputImage = InputImage.fromFilePath(image.path);
        final RecognizedText recognizedText =
            await _textRecognizer.processImage(inputImage);

        for (final block in recognizedText.blocks) {
          double blockConfidence = _calculateEnhancedConfidence(block);
          if (blockConfidence >= 0.6) {
            String cleanText = _cleanText(block.text);
            if (cleanText.isNotEmpty && cleanText.length >= 2) {
              capturedTexts.add(cleanText);
            }
          }
        }

        // Small delay between captures
        if (i < 2) await Future.delayed(const Duration(milliseconds: 100));
      }

      // Find most common text from captures
      String? bestText;
      if (capturedTexts.isNotEmpty) {
        Map<String, int> textCounts = {};
        for (String text in capturedTexts) {
          textCounts[text] = (textCounts[text] ?? 0) + 1;
        }

        int maxCount = 0;
        for (final entry in textCounts.entries) {
          if (entry.value > maxCount) {
            maxCount = entry.value;
            bestText = entry.key;
          }
        }
      }

      setState(() {
        if (bestText != null) {
          _finalDetectedText = bestText;
          _debugInfo = "✅ ENHANCED CAPTURE: '$bestText'";
          HapticFeedback.heavyImpact();
        } else {
          _debugInfo =
              "No reliable text detected. Try different lighting/angle.";
        }
      });
    } catch (e) {
      setState(() {
        _debugInfo = "Error in enhanced capture: $e";
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Magic Text Scanner'),
        backgroundColor: Colors.black87,
        elevation: 4,
        actions: [
          IconButton(
            icon: const Icon(Icons.clear_all),
            onPressed: clearDetectedText,
            tooltip: 'Clear results',
          ),
        ],
      ),
      body: FutureBuilder<void>(
        future: _initializeControllerFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.done) {
            return Column(
              children: [
                // Control buttons
                Container(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          ElevatedButton.icon(
                            onPressed: _isDetecting ? null : startDetection,
                            icon: Icon(_isDetecting
                                ? Icons.hourglass_empty
                                : Icons.play_arrow),
                            label: const Text('Start'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.green[700],
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 20, vertical: 12),
                            ),
                          ),
                          ElevatedButton.icon(
                            onPressed: _isDetecting ? stopDetection : null,
                            icon: const Icon(Icons.stop),
                            label: const Text('Stop'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.red[700],
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 20, vertical: 12),
                            ),
                          ),
                          ElevatedButton.icon(
                            onPressed: enhancedCapture,
                            icon: const Icon(Icons.burst_mode),
                            label: const Text('Burst'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.purple[700],
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 20, vertical: 12),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '💡 Tip: Hold paper steady for 2-3 seconds. App adapts automatically!',
                        style: TextStyle(
                          color: Colors.blue[300],
                          fontSize: 13,
                          fontStyle: FontStyle.italic,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),

                // Enhanced status indicator
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 16),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: _getStatusColor().withOpacity(0.2),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: _getStatusColor(), width: 1),
                  ),
                  child: Row(
                    children: [
                      Icon(_getStatusIcon(),
                          color: _getStatusColor(), size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _debugInfo,
                          style:
                              TextStyle(color: _getStatusColor(), fontSize: 13),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (_isDetecting)
                        Container(
                          margin: const EdgeInsets.only(left: 8),
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(
                                _getStatusColor()),
                          ),
                        ),
                    ],
                  ),
                ),

                const SizedBox(height: 16),

                // Camera preview with enhanced indicators
                Expanded(
                  flex: 3,
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 16),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                          color: _isDetecting ? Colors.green : Colors.white24,
                          width: _isDetecting ? 3 : 2),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Stack(
                        children: [
                          CameraPreview(_controller),

                          // Scanning overlay
                          if (_isDetecting)
                            Positioned.fill(
                              child: Container(
                                decoration: BoxDecoration(
                                  border:
                                      Border.all(color: Colors.green, width: 2),
                                  color: Colors.green.withOpacity(0.1),
                                ),
                                child: const Center(
                                  child: Icon(
                                    Icons.center_focus_strong,
                                    color: Colors.green,
                                    size: 100,
                                  ),
                                ),
                              ),
                            ),

                          // Status badges
                          Positioned(
                            top: 16,
                            right: 16,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                if (_isDetecting)
                                  _buildStatusBadge(
                                      'SCANNING', Colors.green, Icons.search),
                                if (_hasIncreasedSensitivity)
                                  _buildStatusBadge(
                                      'ENHANCED', Colors.orange, Icons.tune),
                                if (_autoFlashEnabled)
                                  _buildStatusBadge('FLASH ON', Colors.yellow,
                                      Icons.flash_on),
                              ],
                            ),
                          ),

                          // Center focus indicator
                          const Positioned.fill(
                            child: Center(
                              child: Icon(
                                Icons.center_focus_weak,
                                color: Colors.white54,
                                size: 60,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 16),

                // Enhanced results section
                Expanded(
                  flex: 1,
                  child: Container(
                    margin: const EdgeInsets.all(16),
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [Colors.grey[900]!, Colors.grey[800]!],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.white12, width: 1),
                    ),
                    child: _finalDetectedText == null
                        ? _buildEmptyState()
                        : _buildResultState(),
                  ),
                ),
              ],
            );
          } else if (snapshot.hasError) {
            return Center(
              child: Text(
                'Error initializing camera: ${snapshot.error}',
                style: const TextStyle(color: Colors.white),
              ),
            );
          } else {
            return const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text(
                    'Initializing camera...',
                    style: TextStyle(color: Colors.white),
                  ),
                ],
              ),
            );
          }
        },
      ),
    );
  }

  Widget _buildStatusBadge(String text, Color color, IconData icon) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.9),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 14),
          const SizedBox(width: 4),
          Text(
            text,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Color _getStatusColor() {
    if (_finalDetectedText != null) return Colors.green;
    if (_isDetecting) return Colors.blue;
    return Colors.grey;
  }

  IconData _getStatusIcon() {
    if (_finalDetectedText != null) return Icons.check_circle;
    if (_isDetecting) return Icons.search;
    return Icons.info_outline;
  }

  Widget _buildEmptyState() {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.text_fields, color: Colors.white38, size: 48),
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

  Widget _buildResultState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.auto_awesome, color: Colors.yellow, size: 48),
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
              _finalDetectedText!,
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
