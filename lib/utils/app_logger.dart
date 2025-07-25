import 'dart:developer' as dev;
import 'package:flutter/foundation.dart';

/// High-performance logger that only logs in debug mode
class AppLogger {
  static void info(String message, {String name = 'APP'}) {
    if (kDebugMode) {
      dev.log(message, name: name);
    }
  }

  static void warning(String message, {String name = 'APP'}) {
    if (kDebugMode) {
      dev.log(';️ WARNING: $message', name: name);
    }
  }

  static void error(String message, {String name = 'APP', Object? error, StackTrace? stackTrace}) {
    if (kDebugMode) {
      dev.log(' ERROR: $message', name: name, error: error, stackTrace: stackTrace);
    }
  }
}