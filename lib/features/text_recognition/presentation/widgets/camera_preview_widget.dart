import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:magic_app/features/text_recognition/presentation/widgets/status_badge_widget.dart';

class CameraPreviewWidget extends StatelessWidget {
  final CameraController controller;
  final bool isDetecting;
  final bool hasIncreasedSensitivity;
  final bool autoFlashEnabled;

  const CameraPreviewWidget({
    super.key,
    required this.controller,
    required this.isDetecting,
    required this.hasIncreasedSensitivity,
    required this.autoFlashEnabled,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: isDetecting ? Colors.green : Colors.white24,
            width: isDetecting ? 3 : 2),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Stack(
          children: [
            CameraPreview(controller),
            if (isDetecting)
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.green, width: 2),
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
            Positioned(
              top: 16,
              right: 16,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (isDetecting)
                    const StatusBadgeWidget(
                      text: 'SCANNING',
                      color: Colors.green,
                      icon: Icons.search,
                    ),
                  if (hasIncreasedSensitivity)
                    const StatusBadgeWidget(
                      text: 'ENHANCED',
                      color: Colors.orange,
                      icon: Icons.tune,
                    ),
                  if (autoFlashEnabled)
                    const StatusBadgeWidget(
                      text: 'FLASH ON',
                      color: Colors.yellow,
                      icon: Icons.flash_on,
                    ),
                ],
              ),
            ),
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
    );
  }
}
