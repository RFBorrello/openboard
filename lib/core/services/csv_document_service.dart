import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:csv/csv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/board_models.dart';

final csvDocumentServiceProvider = Provider<CsvDocumentService>((ref) {
  return const CsvDocumentService();
});

class CsvSaveResult {
  const CsvSaveResult({required this.fileFingerprint, required this.savedAt});

  final String fileFingerprint;
  final DateTime savedAt;
}

class CsvDocumentService {
  const CsvDocumentService();

  String computeHeaderFingerprint(List<String> headers) {
    return sha1.convert(utf8.encode(headers.join('\u001F'))).toString();
  }

  String computeFileFingerprint(String contents) {
    return sha1.convert(utf8.encode(_normalizeLineEndings(contents))).toString();
  }

  Future<String> readFileFingerprintFromDisk(String filePath) async {
    return computeFileFingerprint(await File(filePath).readAsString());
  }

  String computeDocumentFingerprint(
    List<String> headers,
    List<BoardRecord> records,
  ) {
    final rows = _buildRows(headers, records);
    final output = const ListToCsvConverter(eol: '\n').convert(rows);
    return computeFileFingerprint(output);
  }

  Stream<FileSystemEvent> watchDocument(String filePath) {
    final absoluteFile = File(filePath).absolute.path;
    final targetPath = _normalizePath(absoluteFile);
    final tempPath = _normalizePath('$absoluteFile.openboard.tmp');
    final targetName = targetPath.split('/').last;

    return File(absoluteFile).parent.watch(events: FileSystemEvent.all).where((event) {
      final eventPath = _normalizePath(event.path);
      return eventPath == targetPath ||
          eventPath == tempPath ||
          eventPath.split('/').last == targetName;
    });
  }

  List<String> deriveStatusOrder(
    List<BoardRecord> records,
    CsvColumnMapping mapping, {
    List<String> preferredOrder = const [],
  }) {
    final ordered = <String>{};
    for (final status in preferredOrder) {
      final trimmed = status.trim();
      if (trimmed.isNotEmpty) {
        ordered.add(trimmed);
      }
    }
    for (final record in records) {
      final trimmed = record.read(mapping.statusColumn).trim();
      if (trimmed.isNotEmpty) {
        ordered.add(trimmed);
      }
    }
    return ordered.toList(growable: false);
  }

  List<BoardRecord> rekeyRecords(List<BoardRecord> records, List<String> headers) {
    final ordered = [...records]
      ..sort((left, right) => left.sourceRowIndex.compareTo(right.sourceRowIndex));
    final occurrences = <String, int>{};
    final rowKeysById = <String, String>{};

    for (final record in ordered) {
      final signature = _rowSignature(headers, record.values);
      final occurrence = occurrences.update(signature, (count) => count + 1, ifAbsent: () => 0);
      rowKeysById[record.id] = sha1.convert(utf8.encode('$signature|$occurrence')).toString();
    }

    return [
      for (final record in records)
        record.copyWith(rowKey: rowKeysById[record.id] ?? record.rowKey),
    ];
  }

  Future<BoardDocument> openDocument(String filePath) async {
    final input = await File(filePath).readAsString();
    final normalizedInput = _normalizeLineEndings(input);
    final rows = const CsvToListConverter(
      shouldParseNumbers: false,
      eol: '\n',
    ).convert(normalizedInput);
    if (rows.isEmpty) {
      throw const FormatException('The selected CSV file is empty.');
    }

    final stringRows = rows
        .map(
          (row) => row.map((cell) => cell?.toString() ?? '').toList(growable: false),
        )
        .toList(growable: false);

    var headers = _normalizeHeaders(stringRows.first);
    final maxWidth = stringRows.fold<int>(
      headers.length,
      (width, row) => row.length > width ? row.length : width,
    );
    if (headers.length < maxWidth) {
      headers = [
        ...headers,
        for (var index = headers.length; index < maxWidth; index++) 'Column ${index + 1}',
      ];
    }

    var records = <BoardRecord>[];
    var sourceRowIndex = 0;
    for (var rowIndex = 1; rowIndex < stringRows.length; rowIndex++) {
      final normalized = _normalizeRow(stringRows[rowIndex], headers.length);
      if (normalized.every((cell) => cell.trim().isEmpty)) {
        continue;
      }
      records.add(
        BoardRecord(
          id: 'row_$sourceRowIndex',
          rowKey: 'row_$sourceRowIndex',
          sourceRowIndex: sourceRowIndex,
          values: Map<String, String>.fromIterables(headers, normalized),
        ),
      );
      sourceRowIndex++;
    }
    records = rekeyRecords(records, headers);

    return BoardDocument(
      filePath: filePath,
      fileFingerprint: computeFileFingerprint(normalizedInput),
      headers: headers,
      records: records,
      headerFingerprint: computeHeaderFingerprint(headers),
    );
  }

  Future<BoardDocument> reloadDocumentFromDisk(String filePath) async {
    return openDocument(filePath);
  }

  Future<CsvSaveResult> saveDocument(BoardDocument document) async {
    final rows = _buildRows(document.headers, document.records);
    final output = const ListToCsvConverter(eol: '\r\n').convert(rows);
    final target = File(document.filePath);
    final tempFile = File('${document.filePath}.openboard.tmp');

    await tempFile.writeAsString(output);
    if (await target.exists()) {
      await target.delete();
    }
    try {
      await tempFile.rename(document.filePath);
    } on FileSystemException {
      await tempFile.copy(document.filePath);
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
    }

    return CsvSaveResult(
      fileFingerprint: computeFileFingerprint(output),
      savedAt: DateTime.now(),
    );
  }

  List<List<String>> _buildRows(List<String> headers, List<BoardRecord> records) {
    final sortedRecords = [...records]
      ..sort((left, right) => left.sourceRowIndex.compareTo(right.sourceRowIndex));
    return <List<String>>[
      headers,
      for (final record in sortedRecords)
        [for (final header in headers) record.read(header)],
    ];
  }

  List<String> _normalizeHeaders(List<String> headers) {
    return [
      for (var index = 0; index < headers.length; index++)
        headers[index].trim().isEmpty ? 'Column ${index + 1}' : headers[index].trim(),
    ];
  }

  List<String> _normalizeRow(List<String> row, int width) {
    final normalized = List<String>.from(row);
    if (normalized.length < width) {
      normalized.addAll(List<String>.filled(width - normalized.length, ''));
    }
    if (normalized.length > width) {
      return normalized.sublist(0, width);
    }
    return normalized;
  }

  String _rowSignature(List<String> headers, Map<String, String> values) {
    return [for (final header in headers) values[header] ?? ''].join('\u001F');
  }

  String _normalizeLineEndings(String input) {
    return input.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  }

  String _normalizePath(String value) {
    return value.replaceAll('\\', '/').toLowerCase();
  }
}
