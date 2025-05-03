import 'dart:async';
import 'dart:isolate';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

typedef TextRecognizedCallback = void Function(String text);

class TextRecognitionService {
  CameraController? cameraController;
  final TextRecognizer _textRecognizer = TextRecognizer();
  
  bool _isRecognizing = false;
  late List<CameraDescription> _cameras;
  TextRecognizedCallback? _textRecognizedCallback;
  
  Timer? _processingTimer;
  final Map<String, int> _textFrequency = {};
  
  // Isolate for text processing
  Isolate? _isolate;
  ReceivePort? _receivePort;
  SendPort? _sendPort;

  Future<void> initialize() async {
    _cameras = await availableCameras();
    
    if (_cameras.isEmpty) {
      throw Exception('No cameras available');
    }
    
    // Use back camera by default
    final camera = _selectOptimalCamera(_cameras);
    
    cameraController = CameraController(
      camera,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );
    
    await cameraController!.initialize();
    
    // Initialize isolate for text processing
    await _initializeIsolate();
  }
  
  // Select optimal camera (preferably back camera with sufficient resolution)
  CameraDescription _selectOptimalCamera(List<CameraDescription> cameras) {
    // Prefer back camera
    for (var camera in cameras) {
      if (camera.lensDirection == CameraLensDirection.back) {
        return camera;
      }
    }
    // Fall back to any available camera
    return cameras.first;
  }

  Future<void> _initializeIsolate() async {
    _receivePort = ReceivePort();
    _isolate = await Isolate.spawn<SendPort>(
      _processTextIsolate,
      _receivePort!.sendPort,
    );
    
    _sendPort = await _receivePort!.first;
    
    // Listen for processed results
    _receivePort!.listen((message) {
      if (message is List<String> && message.isNotEmpty) {
        for (final text in message) {
          _handleRecognizedText(text);
        }
      }
    });
  }

  // Text processing isolate entry point
  static void _processTextIsolate(SendPort sendPort) {
    final receivePort = ReceivePort();
    sendPort.send(receivePort.sendPort);
    
    receivePort.listen((message) async {
      if (message is InputImage) {
        try {
          final textRecognizer = TextRecognizer();
          final recognizedText = await textRecognizer.processImage(message);
          
          // Extract text blocks with high confidence
          final List<String> processedTexts = [];
          
          for (TextBlock block in recognizedText.blocks) {
            // Only include blocks with high confidence
            if (block.lines.isNotEmpty) {
              String blockText = block.text.trim();
              if (blockText.isNotEmpty) {
                processedTexts.add(blockText);
              }
              
              // Also collect line-level text for more granular recognition
              for (TextLine line in block.lines) {
                String lineText = line.text.trim();
                if (lineText.isNotEmpty && lineText != blockText) {
                  processedTexts.add(lineText);
                }
              }
            }
          }
          
          await textRecognizer.close();
          
          if (processedTexts.isNotEmpty) {
            sendPort.send(processedTexts);
          } else {
            sendPort.send([]);
          }
        } catch (e) {
          sendPort.send([]);
        }
      }
    });
  }

  void _handleRecognizedText(String text) {
    // Filter out very short or likely erroneous texts
    if (text.length < 2) return;
    
    // Apply debouncing to avoid duplicate texts
    // Only report text if seen multiple times
    _textFrequency[text] = (_textFrequency[text] ?? 0) + 1;
    
    if (_textFrequency[text]! >= 2) {
      _textRecognizedCallback?.call(text);
      // Reset the frequency once reported
      _textFrequency[text] = 0;
    }
  }

  void setTextRecognizedCallback(TextRecognizedCallback callback) {
    _textRecognizedCallback = callback;
  }

  void startRecognition() {
    if (_isRecognizing || cameraController == null || !cameraController!.value.isInitialized) {
      return;
    }
    
    _isRecognizing = true;
    _processingTimer = Timer.periodic(const Duration(milliseconds: 500), _processImage);
  }

  void stopRecognition() {
    _isRecognizing = false;
    _processingTimer?.cancel();
    _processingTimer = null;
  }

  Future<void> _processImage(Timer timer) async {
    if (!_isRecognizing || cameraController == null || !cameraController!.value.isInitialized) {
      return;
    }
    
    try {
      final image = await cameraController!.takePicture();
      final inputImage = InputImage.fromFilePath(image.path);
      
      // Send to isolate for processing
      _sendPort?.send(inputImage);
    } catch (e) {
      debugPrint('Error processing image: $e');
    }
  }

  Future<void> dispose() async {
    stopRecognition();
    
    // Close isolate
    _receivePort?.close();
    _isolate?.kill();
    
    // Close ML Kit resources
    await _textRecognizer.close();
    
    // Dispose camera
    await cameraController?.dispose();
  }
}