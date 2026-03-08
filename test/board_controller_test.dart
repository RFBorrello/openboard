import 'package:flutter_test/flutter_test.dart';
import 'package:openboard/core/models/board_models.dart';
import 'package:openboard/core/services/csv_document_service.dart';
import 'package:openboard/features/board/board_controller.dart';

import 'test_helpers.dart';

void main() {
  group('BoardController', () {
    test('auto-detects common CSV field names', () {
      final mapping = CsvColumnMapping.autoDetect([
        'Task Name',
        'Workflow State',
        'Details',
        'Owner',
        'Deadline',
      ]);

      expect(mapping, isNotNull);
      expect(mapping!.titleColumn, 'Task Name');
      expect(mapping.statusColumn, 'Workflow State');
      expect(mapping.descriptionColumn, 'Details');
      expect(mapping.assigneeColumn, 'Owner');
      expect(mapping.dueDateColumn, 'Deadline');
    });

    test('applies auto-detected mapping on file open', () async {
      final file = await writeTempCsv(
        'auto_detect.csv',
        'Task Name,Workflow State,Details,Owner\n'
        'Task A,Todo,First,Alice\n',
      );
      addTearDown(() => file.parent.delete(recursive: true));

      final controller = BoardController(
        const CsvDocumentService(),
        MemoryBoardPreferencesStore(),
      );

      await controller.openFile(file.path);

      expect(controller.state.document?.mapping, isNotNull);
      expect(controller.state.document?.mapping?.titleColumn, 'Task Name');
      expect(controller.state.document?.mapping?.statusColumn, 'Workflow State');
    });

    test('maps, edits, moves, and saves board data', () async {
      final file = await writeTempCsv(
        'controller.csv',
        'Title,Status,Description,Owner\n'
        'Task A,Todo,First,Alice\n'
        'Task B,Done,Second,Bob\n',
      );
      addTearDown(() => file.parent.delete(recursive: true));

      final preferences = MemoryBoardPreferencesStore();
      const service = CsvDocumentService();
      final controller = BoardController(service, preferences);
      const mapping = CsvColumnMapping(
        titleColumn: 'Title',
        statusColumn: 'Status',
        descriptionColumn: 'Description',
        extraVisibleColumns: ['Owner'],
      );

      await controller.openFile(file.path);
      await controller.applyMapping(mapping);
      controller.addColumn('Blocked');

      final newRecordId = controller.createCard(initialStatus: 'Blocked');
      controller.applyRecordValues(newRecordId, {
        'Title': 'Task C',
        'Status': 'Blocked',
        'Description': 'Fresh work',
        'Owner': 'Casey',
      });
      controller.moveRecord('row_0', 'Done');
      controller.renameColumn('Blocked', 'Waiting');
      await controller.saveDocument();

      final reopened = await service.openDocument(file.path);
      final titles = reopened.records.map((record) => record.read('Title')).toList();

      expect(controller.state.recentFiles.first, file.path);
      expect(controller.state.document?.dirty, isFalse);
      expect(titles, contains('Task C'));
      expect(reopened.records.first.read('Status'), 'Done');
      expect(
        reopened.records.singleWhere((record) => record.read('Title') == 'Task C').read('Status'),
        'Waiting',
      );
    });
  });
}
