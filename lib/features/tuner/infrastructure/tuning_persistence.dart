import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class TuningPersistence {
  static const _kPresetName = 'tuning.presetName';
  static const _kOffsets = 'tuning.offsets';

  Future<void> savePresetName(String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kPresetName, name);
  }

  Future<String?> loadPresetName() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kPresetName);
  }

  Future<void> saveOffsets(List<double> offsets) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kOffsets, jsonEncode(offsets));
  }

  Future<List<double>?> loadOffsets() async {
    final prefs = await SharedPreferences.getInstance();
    final s = prefs.getString(_kOffsets);
    if (s == null) return null;
    try {
      final list = (jsonDecode(s) as List).map((e) => (e as num).toDouble()).toList();
      return list;
    } catch (_) {
      return null;
    }
  }
}
