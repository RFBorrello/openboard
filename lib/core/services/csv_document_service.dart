import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:csv/csv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/board_models.dart';

final csvDocumentServiceProvider = Provider<CsvDocumentService>((ref) {
  return const CsvDocumentService();
});

class CsvDocumentService {
  const CsvDocumentService();

  String computeHeaderFingerprint(List<String> headers) {
    return sha1.convert(utf8.encode(headers.join('\u001F'))).toString();
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

  Future<BoardDocument> openDocument(String filePath) async {
    final input = await File(filePath).readAsString();
    final normalizedInput = input.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
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

    final records = <BoardRecord>[];
    var sourceRowIndex = 0;
    for (var rowIndex = 1; rowIndex < stringRows.length; rowIndex++) {
      final normalized = _normalizeRow(stringRows[rowIndex], headers.length);
      if (normalized.every((cell) => cell.trim().isEmpty)) {
        continue;
      }
      records.add(
        BoardRecord(
          id: 'row_$sourceRowIndex',
          sourceRowIndex: sourceRowIndex,
          values: Map<String, String>.fromIterables(headers, normalized),
        ),
      );
      sourceRowIndex++;
    }

    return BoardDocument(
      filePath: filePath,
      headers: headers,
      records: records,
      headerFingerprint: computeHeaderFingerprint(headers),
    );
  }

  Future<void> saveDocument(BoardDocument document) async {
    final sortedRecords = [...document.records]
      ..sort((left, right) => left.sourceRowIndex.compareTo(right.sourceRowIndex));
    final rows = <List<String>>[
      document.headers,
      for (final record in sortedRecords)
        [for (final header in document.headers) record.read(header)],
    ];

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
}
