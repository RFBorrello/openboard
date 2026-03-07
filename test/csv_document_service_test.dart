
import 'package:flutter_test/flutter_test.dart';
import 'package:openboard/core/models/board_models.dart';
import 'package:openboard/core/services/csv_document_service.dart';

import 'test_helpers.dart';

void main() {
  group('CsvDocumentService', () {
    test('round-trips rows and preserves unmapped columns', () async {
      final file = await writeTempCsv(
        'board.csv',
        'Title,Status,Description,Notes\n'
        'Task A,Todo,"Line 1\nLine 2","Keep, commas"\n'
        'Task B,Done,Short note,Still here\n',
      );
      addTearDown(() => file.parent.delete(recursive: true));

      const service = CsvDocumentService();
      final document = await service.openDocument(file.path);
      const mapping = CsvColumnMapping(
        titleColumn: 'Title',
        statusColumn: 'Status',
        descriptionColumn: 'Description',
        extraVisibleColumns: ['Notes'],
      );

      expect(document.headers, ['Title', 'Status', 'Description', 'Notes']);
      expect(document.records.first.read('Description'), 'Line 1\nLine 2');
      expect(document.records.first.read('Notes'), 'Keep, commas');

      final updatedRecords = [
        document.records.first.copyWith(
          values: {
            ...document.records.first.values,
            'Status': 'Doing',
            'Description': 'Updated body',
          },
        ),
        document.records.last,
      ];
      final updatedDocument = document.copyWith(
        mapping: mapping,
        keepExistingMapping: false,
        records: updatedRecords,
        dirty: true,
        statusOrder: service.deriveStatusOrder(updatedRecords, mapping),
      );

      await service.saveDocument(updatedDocument);
      final reopened = await service.openDocument(file.path);

      expect(reopened.records.first.read('Status'), 'Doing');
      expect(reopened.records.first.read('Description'), 'Updated body');
      expect(reopened.records.first.read('Notes'), 'Keep, commas');
      expect(reopened.records.last.read('Notes'), 'Still here');
    });
  });
}

