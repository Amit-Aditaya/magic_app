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

class DetectedText {
  final String text;
  final double confidence;
  final DateTime timestamp;

  DetectedText({
    required this.text,
    required this.confidence,
    required this.timestamp,
  });
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

  // Text stabilization properties
  final Map<String, int> _textCandidates = {};
  final Map<String, double> _textConfidences = {};
  static const int _minimumOccurrences = 3; // Text must appear at least 3 times
  static const double _minimumConfidence = 0.7; // Minimum confidence threshold
  static const int _stabilizationWindowMs = 2000; // 2 second window

  // Focus assistance
  bool _isFocusing = false;
  DateTime? _lastFocusTime;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeCamera();
  }

  void _initializeCamera() {
    _controller = CameraController(
      widget.camera,
      ResolutionPreset.veryHigh, // Highest resolution for best text clarity
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );

    _initializeControllerFuture = _controller.initialize().then((_) {
      if (mounted) {
        setState(() {});
        // Optimize camera settings for document reading
        _optimizeCameraForDocuments();
      }
    }).catchError((error) {
      setState(() {
        _debugInfo = 'Error initializing camera: $error';
      });
      print('Error initializing camera: $error');
    });
  }

  void _optimizeCameraForDocuments() async {
    try {
      // Set focus mode to auto with macro capability if available
      await _controller.setFocusMode(FocusMode.auto);
      await _controller.setExposureMode(ExposureMode.auto);

      // Enable flash for better illumination if needed
      await _controller.setFlashMode(FlashMode.off);

      // Set zoom slightly for better text recognition (if supported)
      final double maxZoom = await _controller.getMaxZoomLevel();
      if (maxZoom > 1.0) {
        await _controller
            .setZoomLevel(1.2); // Slight zoom for better text clarity
      }

      setState(() {
        _debugInfo = "Camera optimized for document reading";
      });
    } catch (e) {
      print('Error optimizing camera: $e');
    }
  }

  @override
  void dispose() {
    stopDetection();
    _detectionTimer?.cancel();
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

      // Clear previous results
      _textCandidates.clear();
      _textConfidences.clear();
      setState(() {
        _finalDetectedText = null;
        _debugInfo = "Starting enhanced text detection...";
      });

      // Start stabilization timer
      _startStabilizationTimer();

      await _controller.startImageStream((CameraImage image) async {
        if (_isProcessing) return;

        _isProcessing = true;
        _isDetecting = true;

        try {
          // Auto-focus periodically for better text clarity
          _autoFocusIfNeeded();

          // Convert and process image with enhanced settings
          final inputImage = await _convertCameraImage(image);
          final RecognizedText recognizedText =
              await _textRecognizer.processImage(inputImage);

          // Process results with confidence filtering
          _processRecognitionResults(recognizedText);
        } catch (e) {
          setState(() {
            _debugInfo = "Error during detection: $e";
          });
          print('Error detecting text: $e');
        } finally {
          // Reduced processing interval for more samples
          await Future.delayed(const Duration(milliseconds: 300));
          _isProcessing = false;
        }
      });
    } catch (e) {
      setState(() {
        _debugInfo = "Error starting detection: $e";
      });
      print('Error starting image stream: $e');
      _isDetecting = false;
    }
  }

  void _autoFocusIfNeeded() async {
    final now = DateTime.now();
    if (_lastFocusTime == null ||
        now.difference(_lastFocusTime!).inMilliseconds > 1500) {
      try {
        setState(() {
          _isFocusing = true;
        });

        // Trigger auto-focus
        await _controller.setFocusPoint(const Offset(0.5, 0.5));
        await _controller.setFocusMode(FocusMode.auto);

        _lastFocusTime = now;

        // Brief delay to let focus complete
        await Future.delayed(const Duration(milliseconds: 200));

        setState(() {
          _isFocusing = false;
        });
      } catch (e) {
        setState(() {
          _isFocusing = false;
        });
        print('Auto-focus error: $e');
      }
    }
  }

  void _startStabilizationTimer() {
    _detectionTimer?.cancel();
    _detectionTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (timer) => _evaluateStabilizedText(),
    );
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
      // Calculate confidence based on block confidence and other factors
      double blockConfidence = _calculateBlockConfidence(block);

      if (blockConfidence >= _minimumConfidence) {
        String cleanText = _cleanText(block.text);

        if (cleanText.isNotEmpty && cleanText.length >= 2) {
          // Add to candidates
          _textCandidates[cleanText] = (_textCandidates[cleanText] ?? 0) + 1;
          _textConfidences[cleanText] =
              (_textConfidences[cleanText] ?? 0.0) + blockConfidence;

          setState(() {
            _debugInfo =
                "Analyzing: '$cleanText' (${_textCandidates[cleanText]} times, avg conf: ${(_textConfidences[cleanText]! / _textCandidates[cleanText]!).toStringAsFixed(2)})";
          });
        }
      }
    }
  }

  double _calculateBlockConfidence(TextBlock block) {
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

    // Boost confidence for longer texts (more likely to be intentional)
    if (block.text.length > 5) {
      avgConfidence *= 1.1;
    }

    // Reduce confidence for very short texts (likely noise)
    if (block.text.length < 3) {
      avgConfidence *= 0.8;
    }

    return avgConfidence.clamp(0.0, 1.0);
  }

  String _cleanText(String text) {
    // Remove extra whitespace and special characters
    return text
        .replaceAll(
            RegExp(r'[^\w\s]'), '') // Remove non-alphanumeric except spaces
        .replaceAll(RegExp(r'\s+'), ' ') // Normalize spaces
        .trim()
        .toUpperCase(); // Uppercase for better matching
  }

  void _evaluateStabilizedText() {
    if (_textCandidates.isEmpty) return;

    // Find the best candidate
    String? bestCandidate;
    double bestScore = 0.0;

    for (final entry in _textCandidates.entries) {
      final String text = entry.key;
      final int occurrences = entry.value;
      final double avgConfidence = _textConfidences[text]! / occurrences;

      // Score combines occurrences and confidence
      double score = (occurrences * 0.6) + (avgConfidence * 0.4);

      if (occurrences >= _minimumOccurrences && score > bestScore) {
        bestScore = score;
        bestCandidate = text;
      }
    }

    // If we found a stable candidate, finalize it
    if (bestCandidate != null && bestCandidate != _finalDetectedText) {
      setState(() {
        _finalDetectedText = bestCandidate;
        _debugInfo =
            "✅ FINAL TEXT DETECTED: '$bestCandidate' (Score: ${bestScore.toStringAsFixed(2)})";
      });

      // Vibrate to indicate successful detection
      HapticFeedback.heavyImpact();

      // Auto-stop detection after successful recognition
      Future.delayed(const Duration(milliseconds: 500), () {
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

    if (_controller.value.isInitialized &&
        _controller.value.isStreamingImages) {
      try {
        _controller.stopImageStream();
      } catch (e) {
        print('Error stopping image stream: $e');
      }
    }
  }

  void clearDetectedText() {
    setState(() {
      _finalDetectedText = null;
      _textCandidates.clear();
      _textConfidences.clear();
      _debugInfo = "Results cleared";
    });
  }

  // Enhanced single capture with multiple processing attempts
  void captureAndProcessSingle() async {
    try {
      await _initializeControllerFuture;

      setState(() {
        _debugInfo = "Capturing optimized image...";
      });

      // Ensure good focus before capture
      await _controller.setFocusPoint(const Offset(0.5, 0.5));
      await _controller.setFocusMode(FocusMode.auto);
      await Future.delayed(const Duration(milliseconds: 300));

      final XFile image = await _controller.takePicture();

      setState(() {
        _debugInfo = "Processing captured image with enhanced settings...";
      });

      final InputImage inputImage = InputImage.fromFilePath(image.path);
      final RecognizedText recognizedText =
          await _textRecognizer.processImage(inputImage);

      // Process with same confidence filtering
      String? bestText;
      double bestConfidence = 0.0;

      for (final block in recognizedText.blocks) {
        double blockConfidence = _calculateBlockConfidence(block);
        if (blockConfidence > bestConfidence &&
            blockConfidence >= _minimumConfidence) {
          bestConfidence = blockConfidence;
          bestText = _cleanText(block.text);
        }
      }

      setState(() {
        if (bestText != null && bestText.isNotEmpty) {
          _finalDetectedText = bestText;
          _debugInfo =
              "✅ CAPTURED TEXT: '$bestText' (Confidence: ${bestConfidence.toStringAsFixed(2)})";
          HapticFeedback.heavyImpact();
        } else {
          _debugInfo = "No reliable text detected in captured image";
        }
      });
    } catch (e) {
      setState(() {
        _debugInfo = "Error capturing/processing image: $e";
      });
      print('Error capturing/processing image: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Magic Text Detection'),
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
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      ElevatedButton.icon(
                        onPressed: _isDetecting ? null : startDetection,
                        icon: Icon(_isDetecting
                            ? Icons.hourglass_empty
                            : Icons.play_arrow),
                        label: const Text('Start Detection'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green[700],
                          foregroundColor: Colors.white,
                        ),
                      ),
                      ElevatedButton.icon(
                        onPressed: _isDetecting ? stopDetection : null,
                        icon: const Icon(Icons.stop),
                        label: const Text('Stop'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red[700],
                          foregroundColor: Colors.white,
                        ),
                      ),
                      ElevatedButton.icon(
                        onPressed: captureAndProcessSingle,
                        icon: const Icon(Icons.camera_alt),
                        label: const Text('Capture'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blue[700],
                          foregroundColor: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),

                // Status indicator
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 16),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: _isDetecting
                        ? Colors.green[900]?.withOpacity(0.3)
                        : Colors.grey[900]?.withOpacity(0.3),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: _isDetecting ? Colors.green : Colors.grey,
                      width: 1,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _isDetecting ? Icons.visibility : Icons.visibility_off,
                        color: _isDetecting ? Colors.green : Colors.grey,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _debugInfo,
                          style: TextStyle(
                            color: _isDetecting
                                ? Colors.green[300]
                                : Colors.grey[300],
                            fontSize: 13,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (_isFocusing)
                        Container(
                          margin: const EdgeInsets.only(left: 8),
                          width: 16,
                          height: 16,
                          child: const CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor:
                                AlwaysStoppedAnimation<Color>(Colors.blue),
                          ),
                        ),
                    ],
                  ),
                ),

                const SizedBox(height: 16),

                // Camera preview
                Expanded(
                  flex: 3,
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 16),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.white24, width: 2),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Stack(
                        children: [
                          CameraPreview(_controller),
                          if (_isDetecting)
                            Positioned(
                              top: 16,
                              right: 16,
                              child: Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: Colors.green.withOpacity(0.8),
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.search,
                                        color: Colors.white, size: 16),
                                    SizedBox(width: 4),
                                    Text(
                                      'SCANNING',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 16),

                // Results section
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
                        ? const Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.text_fields,
                                  color: Colors.white38,
                                  size: 48,
                                ),
                                SizedBox(height: 12),
                                Text(
                                  'No text detected yet',
                                  style: TextStyle(
                                    color: Colors.white54,
                                    fontSize: 16,
                                  ),
                                ),
                                SizedBox(height: 4),
                                Text(
                                  'Place paper with text in front of camera',
                                  style: TextStyle(
                                    color: Colors.white38,
                                    fontSize: 14,
                                  ),
                                ),
                              ],
                            ),
                          )
                        : Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(
                                  Icons.check_circle,
                                  color: Colors.green,
                                  size: 48,
                                ),
                                const SizedBox(height: 16),
                                const Text(
                                  'DETECTED TEXT:',
                                  style: TextStyle(
                                    color: Colors.green,
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
                                    border: Border.all(
                                        color: Colors.green, width: 1),
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
                          ),
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
}
