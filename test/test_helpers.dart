import 'dart:async';
import 'dart:io';

import 'package:openboard/core/models/board_models.dart';
import 'package:openboard/core/services/board_preferences_store.dart';

class MemoryBoardPreferencesStore implements BoardPreferencesStore {
  final Map<String, CsvColumnMapping> _mappings = {};
  final Map<String, List<String>> _statusOrders = {};
  final List<String> _recentFiles = [];

  @override
  Future<CsvColumnMapping?> loadMapping(String filePath, String headerFingerprint) async {
    return _mappings['$filePath|$headerFingerprint'];
  }

  @override
  Future<List<String>?> loadStatusOrder(String filePath, String headerFingerprint) async {
    final statusOrder = _statusOrders['$filePath|$headerFingerprint'];
    return statusOrder == null ? null : List<String>.from(statusOrder);
  }

  @override
  Future<List<String>> loadRecentFiles() async {
    return List<String>.from(_recentFiles);
  }

  @override
  Future<void> saveMapping(
    String filePath,
    String headerFingerprint,
    CsvColumnMapping mapping,
  ) async {
    _mappings['$filePath|$headerFingerprint'] = mapping;
  }

  @override
  Future<void> saveStatusOrder(
    String filePath,
    String headerFingerprint,
    List<String> statusOrder,
  ) async {
    _statusOrders['$filePath|$headerFingerprint'] = List<String>.from(statusOrder);
  }

  @override
  Future<void> saveRecentFile(String filePath) async {
    _recentFiles
      ..remove(filePath)
      ..insert(0, filePath);
  }
}

Future<File> writeTempCsv(String name, String contents) async {
  final directory = await Directory.systemTemp.createTemp('openboard_test_');
  final file = File('${directory.path}/$name');
  await file.writeAsString(contents);
  return file;
}

Future<void> waitForCondition(
  FutureOr<bool> Function() predicate, {
  Duration timeout = const Duration(seconds: 5),
  Duration pollInterval = const Duration(milliseconds: 50),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await predicate()) {
      return;
    }
    await Future<void>.delayed(pollInterval);
  }
  throw TimeoutException('Timed out waiting for condition.');
}
