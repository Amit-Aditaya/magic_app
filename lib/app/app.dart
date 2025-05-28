import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:magic_app/features/text_recognition/presentation/pages/text_recognition_screen.dart';

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
