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
      addTearDown(controller.dispose);

      await controller.openFile(file.path);

      expect(controller.state.document?.mapping, isNotNull);
      expect(controller.state.document?.mapping?.titleColumn, 'Task Name');
      expect(controller.state.document?.mapping?.statusColumn, 'Workflow State');
    });

    test('auto-saves board changes back to the CSV', () async {
      final file = await writeTempCsv(
        'controller.csv',
        'Title,Status,Description,Owner\n'
        'Task A,Todo,First,Alice\n'
        'Task B,Done,Second,Bob\n',
      );
      addTearDown(() => file.parent.delete(recursive: true));

      final preferences = MemoryBoardPreferencesStore();
      const service = CsvDocumentService();
      final controller = BoardController(
        service,
        preferences,
        reloadDebounce: const Duration(milliseconds: 75),
      );
      addTearDown(controller.dispose);

      await controller.openFile(file.path);
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

      await waitForCondition(() {
        final document = controller.state.document;
        return !controller.state.isSaving && document != null && !document.dirty;
      });

      final reopened = await service.openDocument(file.path);
      final titles = reopened.records.map((record) => record.read('Title')).toList();

      expect(controller.state.recentFiles.first, file.path);
      expect(titles, contains('Task C'));
      expect(reopened.records.first.read('Status'), 'Done');
      expect(
        reopened.records.singleWhere((record) => record.read('Title') == 'Task C').read('Status'),
        'Waiting',
      );
    });

    test('reorders status columns and persists the preferred order', () async {
      final file = await writeTempCsv(
        'column_order.csv',
        'Title,Status\n'
        'Task A,Todo\n'
        'Task B,In Progress\n'
        'Task C,Done\n',
      );
      addTearDown(() => file.parent.delete(recursive: true));

      final preferences = MemoryBoardPreferencesStore();
      const service = CsvDocumentService();
      final controller = BoardController(service, preferences);
      addTearDown(controller.dispose);

      await controller.openFile(file.path);

      expect(
        controller.buildColumns().map((column) => column.name).toList(),
        ['Todo', 'In Progress', 'Done'],
      );

      controller.moveColumn('Done', -1);
      controller.moveColumn('Done', -1);

      expect(
        controller.buildColumns().map((column) => column.name).toList(),
        ['Done', 'Todo', 'In Progress'],
      );

      final reopenedController = BoardController(service, preferences);
      addTearDown(reopenedController.dispose);
      await reopenedController.openFile(file.path);

      expect(
        reopenedController.buildColumns().map((column) => column.name).toList(),
        ['Done', 'Todo', 'In Progress'],
      );
    });

    test('reloads external CSV changes and preserves selection and column order', () async {
      final file = await writeTempCsv(
        'external_update.csv',
        'Title,Status\n'
        'Task A,Todo\n'
        'Task B,Done\n',
      );
      addTearDown(() => file.parent.delete(recursive: true));

      final controller = BoardController(
        const CsvDocumentService(),
        MemoryBoardPreferencesStore(),
        reloadDebounce: const Duration(milliseconds: 75),
      );
      addTearDown(controller.dispose);

      await controller.openFile(file.path);
      controller.moveColumn('Done', -1);
      controller.selectRecord('row_0');

      await file.writeAsString(
        'Title,Status\n'
        'Task A,Todo\n'
        'Task B,Done\n'
        'Task C,Todo\n',
      );

      await waitForCondition(() {
        return controller.state.document?.records.length == 3 &&
            controller.state.syncStatus == BoardSyncStatus.externalUpdate;
      });

      expect(controller.state.selectedRecordId, 'row_0');
      expect(
        controller.buildColumns().map((column) => column.name).toList(),
        ['Done', 'Todo'],
      );
      expect(
        controller.state.document?.records.any((record) => record.read('Title') == 'Task C'),
        isTrue,
      );
    });

    test('invalidates mapping when external headers change', () async {
      final file = await writeTempCsv(
        'schema_drift.csv',
        'Title,Status,Description\n'
        'Task A,Todo,First\n',
      );
      addTearDown(() => file.parent.delete(recursive: true));

      final controller = BoardController(
        const CsvDocumentService(),
        MemoryBoardPreferencesStore(),
        reloadDebounce: const Duration(milliseconds: 75),
      );
      addTearDown(controller.dispose);

      await controller.openFile(file.path);
      final originalFingerprint = controller.state.document?.headerFingerprint;

      await file.writeAsString(
        'Task,Stage,Notes\n'
        'Task A,Todo,First\n',
      );

      await waitForCondition(() {
        final document = controller.state.document;
        return document != null &&
            document.headerFingerprint != originalFingerprint &&
            document.mapping == null;
      });

      expect(controller.state.syncStatus, BoardSyncStatus.externalUpdate);
      expect(
        controller.state.syncMessage,
        contains('Review the field mapping'),
      );
    });

    test('stops reacting to the old file after switching to a new one', () async {
      final firstFile = await writeTempCsv(
        'first.csv',
        'Title,Status\nTask A,Todo\n',
      );
      final secondFile = await writeTempCsv(
        'second.csv',
        'Title,Status\nTask B,Done\n',
      );
      addTearDown(() => firstFile.parent.delete(recursive: true));
      addTearDown(() => secondFile.parent.delete(recursive: true));

      final controller = BoardController(
        const CsvDocumentService(),
        MemoryBoardPreferencesStore(),
        reloadDebounce: const Duration(milliseconds: 75),
      );
      addTearDown(controller.dispose);

      await controller.openFile(firstFile.path);
      await controller.openFile(secondFile.path);

      await firstFile.writeAsString(
        'Title,Status\nTask A,Done\nTask C,Todo\n',
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(controller.state.document?.filePath, secondFile.path);
      expect(
        controller.state.document?.records.map((record) => record.read('Title')).toList(),
        ['Task B'],
      );
    });
  });
}

