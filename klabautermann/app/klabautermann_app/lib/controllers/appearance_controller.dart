import 'package:flutter/material.dart';

/// The app's appearance concern (03 §10.1: one `ChangeNotifier` controller
/// per concern). Its [themeMode] is the only input `MaterialApp` rebuilds
/// on; persistence lands with the settings store in a later milestone.
final class AppearanceController extends ChangeNotifier {
  ThemeMode _themeMode = ThemeMode.system;

  ThemeMode get themeMode => _themeMode;

  set themeMode(ThemeMode value) {
    if (value == _themeMode) return;
    _themeMode = value;
    notifyListeners();
  }
}
