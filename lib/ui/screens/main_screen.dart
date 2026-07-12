import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../core/theme/app_theme.dart';
import 'pulse_layer.dart';

/// Slate — Main Screen
/// StatelessWidget. Single entry point for the app body.

class MainScreen extends StatelessWidget {
  const MainScreen({super.key});

  @override
  Widget build(BuildContext context) {
    if (kDebugMode) print('MainScreen build()');
    
    return Scaffold(
      backgroundColor: AppTheme.background,
      body: const PulseLayer(),
    );
  }
}
