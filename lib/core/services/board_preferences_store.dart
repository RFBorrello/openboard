import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/board_models.dart';

final boardPreferencesStoreProvider = Provider<BoardPreferencesStore>((ref) {
  return FileBoardPreferencesStore();
});

abstract class BoardPreferencesStore {
  Future<CsvColumnMapping?> loadMapping(String filePath, String headerFingerprint);

  Future<void> saveMapping(
    String filePath,
    String headerFingerprint,
    CsvColumnMapping mapping,
  );

  Future<List<String>> loadRecentFiles();

  Future<void> saveRecentFile(String filePath);
}

class FileBoardPreferencesStore implements BoardPreferencesStore {
  FileBoardPreferencesStore({File? storageFile})
      : _storageFile = storageFile ?? File(_defaultStoragePath());

  final File _storageFile;

  static String _defaultStoragePath() {
    if (Platform.isWindows) {
      final root =
          Platform.environment['APPDATA'] ?? Platform.environment['USERPROFILE'] ?? '.';
      return '$root\\OpenBoard\\preferences.json';
    }
    if (Platform.isMacOS) {
      final home = Platform.environment['HOME'] ?? '.';
      return '$home/Library/Application Support/OpenBoard/preferences.json';
    }
    final home = Platform.environment['HOME'] ?? '.';
    final configRoot = Platform.environment['XDG_CONFIG_HOME'] ?? '$home/.config';
    return '$configRoot/openboard/preferences.json';
  }

  String _mappingKey(String filePath, String headerFingerprint) {
    final raw = utf8.encode('$filePath|$headerFingerprint');
    return base64UrlEncode(raw);
  }

  @override
  Future<CsvColumnMapping?> loadMapping(
    String filePath,
    String headerFingerprint,
  ) async {
    final data = await _readData();
    final mappings = data['mappings'] as Map<String, dynamic>? ?? const {};
    final raw = mappings[_mappingKey(filePath, headerFingerprint)];
    if (raw is! Map<String, dynamic>) {
      return null;
    }
    try {
      return CsvColumnMapping.fromJson(raw);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<List<String>> loadRecentFiles() async {
    final data = await _readData();
    return (data['recentFiles'] as List<dynamic>? ?? const [])
        .whereType<String>()
        .toList(growable: false);
  }

  @override
  Future<void> saveMapping(
    String filePath,
    String headerFingerprint,
    CsvColumnMapping mapping,
  ) async {
    final data = await _readData();
    final mappings = Map<String, dynamic>.from(
      data['mappings'] as Map<String, dynamic>? ?? const {},
    );
    mappings[_mappingKey(filePath, headerFingerprint)] = mapping.toJson();
    data['mappings'] = mappings;
    await _writeData(data);
  }

  @override
  Future<void> saveRecentFile(String filePath) async {
    final data = await _readData();
    final current = (data['recentFiles'] as List<dynamic>? ?? const [])
        .whereType<String>()
        .where((path) => path != filePath)
        .toList();
    data['recentFiles'] = [filePath, ...current].take(10).toList();
    await _writeData(data);
  }

  Future<Map<String, dynamic>> _readData() async {
    if (!await _storageFile.exists()) {
      return <String, dynamic>{};
    }
    try {
      final decoded = jsonDecode(await _storageFile.readAsString());
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } catch (_) {
      return <String, dynamic>{};
    }
    return <String, dynamic>{};
  }

  Future<void> _writeData(Map<String, dynamic> data) async {
    await _storageFile.parent.create(recursive: true);
    await _storageFile.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
  }
}
