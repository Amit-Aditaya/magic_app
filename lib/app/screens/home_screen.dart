import 'package:flutter/material.dart';

import '../services/text_recognition_service.dart';
import '../widgets/camera_view.dart';
import '../widgets/recognized_text_list.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final TextRecognitionService _textRecognitionService = TextRecognitionService();
  final List<String> _recognizedTexts = [];
  bool _isProcessing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeService();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _textRecognitionService.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Handle app lifecycle changes
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      if (_isProcessing) {
        _toggleProcessing();
      }
    }
  }

  Future<void> _initializeService() async {
    try {
      await _textRecognitionService.initialize();
      _textRecognitionService.setTextRecognizedCallback(_onTextRecognized);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error initializing camera: $e')),
        );
      }
    }
  }

  void _onTextRecognized(String text) {
    if (text.isNotEmpty && !_recognizedTexts.contains(text)) {
      setState(() {
        _recognizedTexts.add(text);
      });
    }
  }

  void _toggleProcessing() {
    setState(() {
      _isProcessing = !_isProcessing;
      if (_isProcessing) {
        _textRecognitionService.startRecognition();
      } else {
        _textRecognitionService.stopRecognition();
      }
    });
  }

  void _clearRecognizedTexts() {
    setState(() {
      _recognizedTexts.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  ElevatedButton.icon(
                    onPressed: _toggleProcessing,
                    icon: Icon(_isProcessing ? Icons.stop : Icons.play_arrow),
                    label: Text(_isProcessing ? 'Stop' : 'Start'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _isProcessing ? Colors.red : Colors.green,
                      foregroundColor: Colors.white,
                    ),
                  ),
                  IconButton(
                    onPressed: _clearRecognizedTexts,
                    icon: const Icon(Icons.delete),
                    tooltip: 'Clear List',
                  ),
                ],
              ),
            ),
            // Camera view takes approximately half of the screen
            Expanded(
              flex: 1,
              child: CameraView(
                controller: _textRecognitionService.cameraController,
                isProcessing: _isProcessing,
              ),
            ),
            // List of recognized texts
            Expanded(
              flex: 1,
              child: RecognizedTextList(recognizedTexts: _recognizedTexts),
            ),
          ],
        ),
      ),
    );
  }
}