import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// Classe utilitaire pour écrire les logs de debug dans un fichier
class DebugLogger {
  static DebugLogger? _instance;
  static File? _logFile;
  static bool _initialized = false;

  DebugLogger._();

  static DebugLogger get instance {
    _instance ??= DebugLogger._();
    return _instance!;
  }

  /// Initialise le fichier de log
  Future<void> init() async {
    if (_initialized) return;

    try {
      // Sur Android, utilise getExternalStorageDirectory pour accéder au stockage externe
      // Sur les autres plateformes, utilise getApplicationDocumentsDirectory
      Directory? directory;
      if (Platform.isAndroid) {
        directory = await getExternalStorageDirectory();
      } else {
        directory = await getApplicationDocumentsDirectory();
      }

      if (directory == null) {
        throw Exception('Unable to get storage directory');
      }

      _logFile = File('${directory.path}/dominant_tracker_debug.log');

      // Écrit l'en-tête du fichier
      await _logFile!.writeAsString(
        '=== DOMINANT PITCH TRACKER DEBUG LOG ===\n'
        'Started: ${DateTime.now().toIso8601String()}\n'
        'Log file: ${_logFile!.path}\n'
        '=========================================\n\n',
        mode: FileMode.write,
      );

      _initialized = true;
      print('═══════════════════════════════════════════════════════');
      print('DEBUG LOG ENABLED');
      print('Log file: ${_logFile!.path}');
      print('═══════════════════════════════════════════════════════');
    } catch (e) {
      print('[DebugLogger] Failed to initialize log file: $e');
    }
  }

  /// Écrit un message dans le fichier de log
  Future<void> log(String message) async {
    if (!_initialized) {
      await init();
    }

    if (_logFile != null) {
      try {
        final timestamp = DateTime.now().toIso8601String();
        await _logFile!.writeAsString(
          '[$timestamp] $message\n',
          mode: FileMode.append,
        );
      } catch (e) {
        print('[DebugLogger] Failed to write log: $e');
      }
    }
  }

  /// Écrit un message synchrone (attention: peut bloquer le thread UI)
  void logSync(String message) {
    if (!_initialized) {
      // Si pas initialisé, on utilise print pour éviter le blocage
      print('[SYNC LOG] $message');
      return;
    }

    if (_logFile != null) {
      try {
        final timestamp = DateTime.now().toIso8601String();
        _logFile!.writeAsStringSync(
          '[$timestamp] $message\n',
          mode: FileMode.append,
        );
      } catch (e) {
        print('[DebugLogger] Failed to write log sync: $e');
      }
    }
  }

  /// Retourne le chemin du fichier de log
  String? get logFilePath => _logFile?.path;

  /// Efface le contenu du fichier de log
  Future<void> clear() async {
    if (_logFile != null) {
      try {
        await _logFile!.writeAsString('');
        print('[DebugLogger] Log file cleared');
      } catch (e) {
        print('[DebugLogger] Failed to clear log file: $e');
      }
    }
  }
}
