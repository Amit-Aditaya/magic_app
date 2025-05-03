import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:permission_handler/permission_handler.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Request camera permission
  await Permission.camera.request();
  
  // Get available cameras
  final cameras = await availableCameras();
  if (cameras.isEmpty) {
    print('No cameras available');
    return;
  }
  
  // Use the first available camera
  final firstCamera = cameras.first;
  
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      home: TextRecognitionScreen(camera: firstCamera),
    ),
  );
}

class TextRecognitionScreen extends StatefulWidget {
  final CameraDescription camera;
  
  const TextRecognitionScreen({Key? key, required this.camera}) : super(key: key);

  @override
  _TextRecognitionScreenState createState() => _TextRecognitionScreenState();
}

class _TextRecognitionScreenState extends State<TextRecognitionScreen> {
  late CameraController _cameraController;
  final TextRecognizer _textRecognizer = TextRecognizer();
  bool _isProcessing = false;
  bool _isRecognizing = false;
  List<String> _recognizedTextList = [];
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _initializeCamera();
  }

  Future<void> _initializeCamera() async {
    _cameraController = CameraController(
      widget.camera,
      ResolutionPreset.medium,
      enableAudio: false,
    );

    try {
      await _cameraController.initialize();
      setState(() {});
    } catch (e) {
      print('Error initializing camera: $e');
    }
  }

  void _toggleTextRecognition() {
    setState(() {
      _isRecognizing = !_isRecognizing;
      
      if (_isRecognizing) {
        // Start recognition at regular intervals
        _timer = Timer.periodic(const Duration(seconds: 2), (_) {
          if (!_isProcessing) {
            _processImage();
          }
        });
      } else {
        // Stop recognition
        _timer?.cancel();
        _timer = null;
      }
    });
  }

  void _clearRecognizedText() {
    setState(() {
      _recognizedTextList.clear();
    });
  }

  Future<void> _processImage() async {
    if (!_cameraController.value.isInitialized || _isProcessing) return;

    setState(() {
      _isProcessing = true;
    });

    try {
      // Capture image
      final XFile file = await _cameraController.takePicture();
      
      // Create input image from file
      final InputImage inputImage = InputImage.fromFilePath(file.path);
      
      // Process the image
      final RecognizedText recognizedText = await _textRecognizer.processImage(inputImage);
      
      // Extract and add text to list
      if (recognizedText.text.isNotEmpty) {
        setState(() {
          // Add each line as a separate item
          for (TextBlock block in recognizedText.blocks) {
            for (TextLine line in block.lines) {
              if (line.text.trim().isNotEmpty && 
                  !_recognizedTextList.contains(line.text.trim())) {
                _recognizedTextList.add(line.text.trim());
              }
            }
          }
        });
      }
      
      // Delete the temporary image file
      await File(file.path).delete();
    } catch (e) {
      print('Error recognizing text: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isProcessing = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _cameraController.dispose();
    _textRecognizer.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_cameraController.value.isInitialized) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // Control buttons at the top
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _isRecognizing ? Colors.red : Colors.green,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                    ),
                    onPressed: _toggleTextRecognition,
                    child: Text(_isRecognizing ? 'Stop' : 'Start'),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline, size: 28),
                    onPressed: _clearRecognizedText,
                    tooltip: 'Clear recognized text',
                  ),
                ],
              ),
            ),
            
            // Camera preview - approximately half of the screen
            Expanded(
              flex: 5,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: CameraPreview(_cameraController),
                ),
              ),
            ),
            
            // Recognized text list - remaining half
            Expanded(
              flex: 5,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Row(
                      children: [
                        const Icon(Icons.text_fields),
                        const SizedBox(width: 8),
                        Text(
                          'Recognized Text',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ],
                    ),
                  ),
                  
                  // List of recognized text
                  Expanded(
                    child: _recognizedTextList.isEmpty
                        ? const Center(
                            child: Text(
                              'No text recognized yet',
                              style: TextStyle(color: Colors.grey),
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.symmetric(horizontal: 16.0),
                            itemCount: _recognizedTextList.length,
                            itemBuilder: (context, index) {
                              return Card(
                                margin: const EdgeInsets.only(bottom: 8.0),
                                child: Padding(
                                  padding: const EdgeInsets.all(12.0),
                                  child: Text(
                                    _recognizedTextList[index],
                                    style: const TextStyle(fontSize: 16),
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}