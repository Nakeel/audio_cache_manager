import 'dart:async';
import 'dart:io';
import 'package:audio_cache_manager/utils/app_logger.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

class InternetChecker {
  final StreamController<bool> _controller = StreamController<bool>.broadcast();
  Stream<bool> get onStatusChange => _controller.stream;

  bool _hasInternet = false;
  Timer? _timer;
  late StreamSubscription _connectivitySubscription;

  bool get hasInternet => _hasInternet;

  static const _loggerName = 'InternetChecker';

  // --- New fields for dynamic ping interval ---
  static const Duration _shortPingInterval = Duration(seconds: 5);
  static const Duration _longPingInterval = Duration(seconds: 15);
  int _failedCheckCount = 0;
  static const int _failureThreshold = 20; // Number of failed calls before increasing ping time
  Duration _currentPingInterval = _longPingInterval; // Start with the long interval
  // --- End new fields ---

  InternetChecker() {
    AppLogger.info('Initializing InternetChecker...', name: _loggerName);
    Future.sync(() => checkInternet());
    _startMonitoring();
  }

  void _startMonitoring() {
    AppLogger.info('Started monitoring connectivity changes.', name: _loggerName);

    _connectivitySubscription = Connectivity()
        .onConnectivityChanged
        .map((result) =>
        [ConnectivityResult.wifi, ConnectivityResult.mobile, ConnectivityResult.ethernet].contains(result))
        .listen((isConnected) {
      if (isConnected) {
        AppLogger.info('Connectivity change detected: connected, rechecking internet...', name: _loggerName);
        checkInternet();
      } else {
        AppLogger.info('Connectivity change detected: no connection.', name: _loggerName);
        if (_hasInternet) {
          _hasInternet = false;
          _controller.add(false);
          AppLogger.info('Broadcasted internet disconnected.', name: _loggerName);
          // Network just went off, shorten ping interval
          _failedCheckCount = 0; // Reset failure count on initial disconnect
          _setCurrentPingInterval(_shortPingInterval);
        }
      }
    });

    _startPeriodicCheck(); // Initial call to set up the timer
  }

  // Helper to manage the periodic timer
  void _startPeriodicCheck() {
    _timer?.cancel(); // Cancel any existing timer
    _timer = Timer.periodic(_currentPingInterval, (timer) {
      AppLogger.info('Periodic internet check triggered (interval: ${_currentPingInterval.inSeconds}s).', name: _loggerName);
      checkInternet();
    });
    AppLogger.info('Periodic check restarted with interval: ${_currentPingInterval.inSeconds}s.', name: _loggerName);
  }

  // Helper to change the ping interval and restart the timer
  void _setCurrentPingInterval(Duration newInterval) {
    if (_currentPingInterval != newInterval) {
      _currentPingInterval = newInterval;
      _startPeriodicCheck();
    }
  }

  Future<void> checkInternet() async {
    AppLogger.info('Checking network availability...', name: _loggerName);
    bool networkAvailable = await _isNetworkAvailable();

    if (!networkAvailable) {
      AppLogger.info('No network available.', name: _loggerName);
      if (_hasInternet) {
        // Only broadcast disconnected if it was previously connected
        _hasInternet = false;
        _controller.add(false);
        AppLogger.info('Broadcasted internet disconnected.', name: _loggerName);
        _failedCheckCount = 0; // Reset failure count on initial disconnect
        _setCurrentPingInterval(_shortPingInterval); // Shorten ping interval
      } else {
        // Still no internet, increment failed count
        _failedCheckCount++;
        AppLogger.info('Consecutive failed check: $_failedCheckCount', name: _loggerName);
        if (_failedCheckCount >= _failureThreshold && _currentPingInterval == _shortPingInterval) {
          AppLogger.info('Failure threshold reached. Increasing ping interval to long.', name: _loggerName);
          _setCurrentPingInterval(_longPingInterval); // Increase ping interval
        }
      }
      return;
    }

    AppLogger.info('Network available, checking internet access...', name: _loggerName);
    bool internetAccessible = await _canAccessInternet();

    if (_hasInternet != internetAccessible) {
      _hasInternet = internetAccessible;
      _controller.add(_hasInternet);
      AppLogger.info(
        'Internet access changed: ${_hasInternet ? 'connected' : 'disconnected'}.',
        name: _loggerName,
      );
    }

    if (internetAccessible) {
      // Internet is back, reset everything to long interval
      _failedCheckCount = 0;
      _setCurrentPingInterval(_longPingInterval);
    }
  }

  Future<bool> _isNetworkAvailable() async {
    var connectivityResult = await Connectivity().checkConnectivity();
    final isAvailable = connectivityResult.contains(ConnectivityResult.wifi) ||
        connectivityResult.contains(ConnectivityResult.mobile) ||
        connectivityResult.contains(ConnectivityResult.ethernet);
    AppLogger.info('Network check result: $connectivityResult -> Available: $isAvailable', name: _loggerName);
    return isAvailable;
  }

  Future<bool> _canAccessInternet() async {
    try {
      final result = await InternetAddress.lookup('google.com');
      final accessible = result.isNotEmpty && result[0].rawAddress.isNotEmpty;
      AppLogger.info('Internet DNS lookup succeeded: Accessible = $accessible', name: _loggerName);
      return accessible;
    } catch (e) {
      AppLogger.info('Internet check failed: $e', name: _loggerName);
      return false;
    }
  }

  void dispose() {
    AppLogger.info('Disposing InternetChecker...', name: _loggerName);
    _controller.close();
    _timer?.cancel();
    _connectivitySubscription.cancel();
  }
}