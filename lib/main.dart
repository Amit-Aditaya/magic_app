import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

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
    );
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
  List<String> _detectedTexts = [];
  final TextRecognizer _textRecognizer =
      TextRecognizer(script: TextRecognitionScript.latin);
  bool _isProcessing = false;
  String _debugInfo = "";

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeCamera();
  }

  void _initializeCamera() {
    _controller = CameraController(
      widget.camera,
      ResolutionPreset
          .high, // Changed from medium to high for better recognition
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup
          .yuv420, // Explicitly set format for better compatibility
    );
    _initializeControllerFuture = _controller.initialize().then((_) {
      if (mounted) {
        setState(() {});
        // Set focus and exposure after initialization
        _controller.setFocusMode(FocusMode.auto);
        _controller.setExposureMode(ExposureMode.auto);
      }
    }).catchError((error) {
      setState(() {
        _debugInfo = 'Error initializing camera: $error';
      });
      print('Error initializing camera: $error');
    });
  }

  @override
  void dispose() {
    stopDetection();
    _controller.dispose();
    _textRecognizer.close();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Handle app lifecycle changes
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

      // If already detecting, return
      if (_controller.value.isStreamingImages) return;

      setState(() {
        _debugInfo = "Starting image stream...";
      });
      print("Starting image stream...");

      await _controller.startImageStream((CameraImage image) async {
        if (_isProcessing) return;

        _isProcessing = true;
        _isDetecting = true;

        try {
          setState(() {
            _debugInfo = "Processing image: ${image.width}x${image.height}";
          });
          print("Processing image: ${image.width}x${image.height}");

          // Convert CameraImage to InputImage
          final WriteBuffer allBytes = WriteBuffer();
          for (final Plane plane in image.planes) {
            allBytes.putUint8List(plane.bytes);
          }
          final bytes = allBytes.done().buffer.asUint8List();

          final Size imageSize =
              Size(image.width.toDouble(), image.height.toDouble());

          final camera = widget.camera;
          final imageRotation = _getRotationValue(camera.sensorOrientation);

          final inputImageFormat =
              InputImageFormatValue.fromRawValue(image.format.raw) ??
                  InputImageFormat.yuv420;

          final inputImage = InputImage.fromBytes(
            bytes: bytes,
            metadata: InputImageMetadata(
              size: imageSize,
              rotation: imageRotation,
              format: inputImageFormat,
              bytesPerRow: image.planes[0].bytesPerRow,
            ),
          );

          final RecognizedText recognizedText =
              await _textRecognizer.processImage(inputImage);

          String debugText =
              "Recognition result: ${recognizedText.text.isEmpty ? 'No text found' : 'Text detected'}";
          if (recognizedText.blocks.isNotEmpty) {
            for (final block in recognizedText.blocks) {
              debugText += "\nBlock text: ${block.text}";
            }
          }
          setState(() {
            _debugInfo = debugText;
          });
          print(debugText);

          if (recognizedText.text.isNotEmpty && mounted) {
            setState(() {
              _detectedTexts.insert(0, recognizedText.text);
              // Limit the list size to prevent memory issues
              if (_detectedTexts.length > 20) {
                _detectedTexts = _detectedTexts.sublist(0, 20);
              }
            });
          }
        } catch (e) {
          setState(() {
            _debugInfo = "Error detecting text: $e";
          });
          print('Error detecting text: $e');
        } finally {
          // Reduced delay to process more frames
          await Future.delayed(const Duration(milliseconds: 200));
          _isProcessing = false;
        }
      });
    } catch (e) {
      setState(() {
        _debugInfo = "Error starting image stream: $e";
      });
      print('Error starting image stream: $e');
      _isDetecting = false;
    }
  }

  InputImageRotation _getRotationValue(int sensorOrientation) {
    // Get the device orientation
    final deviceOrientation = MediaQuery.of(context).orientation;

    // Calculate rotation compensation based on device and sensor orientation
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

    // Map rotation to InputImageRotation value
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

    // Check if controller is initialized and streaming before stopping
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
      _detectedTexts.clear();
    });
  }

  // New function to take a single photo and process it
  void captureAndProcessSingle() async {
    try {
      await _initializeControllerFuture;

      setState(() {
        _debugInfo = "Capturing single image...";
      });

      final XFile image = await _controller.takePicture();

      setState(() {
        _debugInfo = "Processing captured image...";
      });

      final InputImage inputImage = InputImage.fromFilePath(image.path);
      final RecognizedText recognizedText =
          await _textRecognizer.processImage(inputImage);

      String debugText =
          "Recognition result: ${recognizedText.text.isEmpty ? 'No text found' : 'Text detected'}";
      if (recognizedText.blocks.isNotEmpty) {
        for (final block in recognizedText.blocks) {
          debugText += "\nBlock text: ${block.text}";
        }
      }

      setState(() {
        _debugInfo = debugText;
        if (recognizedText.text.isNotEmpty) {
          _detectedTexts.insert(0, recognizedText.text);
          if (_detectedTexts.length > 20) {
            _detectedTexts = _detectedTexts.sublist(0, 20);
          }
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
        title: const Text('Live Text Recognition'),
        backgroundColor: Colors.black,
        actions: [
          IconButton(
            icon: const Icon(Icons.delete),
            onPressed: clearDetectedText,
            tooltip: 'Clear detected text',
          ),
        ],
      ),
      body: FutureBuilder<void>(
        future: _initializeControllerFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.done) {
            return Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    ElevatedButton(
                      onPressed: _isDetecting ? null : startDetection,
                      child: const Text('Start Stream'),
                    ),
                    ElevatedButton(
                      onPressed: _isDetecting ? stopDetection : null,
                      child: const Text('Stop Stream'),
                    ),
                    ElevatedButton(
                      onPressed: captureAndProcessSingle,
                      child: const Text('Capture Single'),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                // Debug info display
                Container(
                  padding: const EdgeInsets.all(8),
                  color: Colors.grey[800],
                  width: double.infinity,
                  child: Text(
                    'Debug: $_debugInfo',
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(height: 10),
                Expanded(
                  flex: 2,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: CameraPreview(_controller),
                  ),
                ),
                const SizedBox(height: 10),
                Expanded(
                  flex: 1,
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.grey[900],
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: _detectedTexts.isEmpty
                        ? const Center(
                            child: Text(
                              'No text detected yet',
                              style: TextStyle(color: Colors.white70),
                            ),
                          )
                        : ListView.builder(
                            itemCount: _detectedTexts.length,
                            itemBuilder: (context, index) {
                              return Card(
                                color: Colors.grey[800],
                                margin: const EdgeInsets.symmetric(vertical: 4),
                                child: Padding(
                                  padding: const EdgeInsets.all(8),
                                  child: Text(
                                    _detectedTexts[index],
                                    style: const TextStyle(
                                        color: Colors.white, fontSize: 16),
                                  ),
                                ),
                              );
                            },
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
            return const Center(child: CircularProgressIndicator());
          }
        },
      ),
    );
  }
}
