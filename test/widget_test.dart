import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openboard/core/models/board_models.dart';
import 'package:openboard/features/board/widgets/mapping_dialog.dart';

void main() {
  testWidgets('mapping dialog returns a valid mapping', (tester) async {
    CsvColumnMapping? result;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            return Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () async {
                    result = await showDialog<CsvColumnMapping>(
                      context: context,
                      builder: (_) => const MappingDialog(
                        headers: ['Title', 'Status', 'Description', 'Owner'],
                      ),
                    );
                  },
                  child: const Text('Open dialog'),
                ),
              ),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('Open dialog'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save mapping'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.titleColumn, 'Title');
    expect(result!.statusColumn, 'Status');
  });
}
