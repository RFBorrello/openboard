import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/board_models.dart';
import '../../core/services/csv_file_picker_service.dart';
import 'board_controller.dart';
import 'widgets/column_name_dialog.dart';
import 'widgets/csv_path_dialog.dart';
import 'widgets/mapping_dialog.dart';
import 'widgets/record_editor.dart';

class BoardPage extends ConsumerStatefulWidget {
  const BoardPage({super.key});

  @override
  ConsumerState<BoardPage> createState() => _BoardPageState();
}

class _BoardPageState extends ConsumerState<BoardPage> {
  String? _lastPromptedFingerprint;

  @override
  Widget build(BuildContext context) {
    ref.listen<BoardState>(boardControllerProvider, (previous, next) {
      final error = next.errorMessage;
      if (error != null && error != previous?.errorMessage) {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(SnackBar(content: Text(error)));
        ref.read(boardControllerProvider.notifier).clearError();
      }

      final syncMessage = next.syncMessage;
      if (syncMessage != null && syncMessage != previous?.syncMessage) {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(SnackBar(content: Text(syncMessage)));
        ref.read(boardControllerProvider.notifier).clearSyncMessage();
      }

      final document = next.document;
      if (document != null &&
          document.mapping == null &&
          document.headerFingerprint != _lastPromptedFingerprint) {
        _lastPromptedFingerprint = document.headerFingerprint;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _openMappingDialog(document);
          }
        });
      }
    });

    final state = ref.watch(boardControllerProvider);
    final document = state.document;
    final canSave = document != null &&
        document.mapping != null &&
        !state.isSaving &&
        (document.dirty || state.syncStatus == BoardSyncStatus.error);

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 88,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'OpenBoard',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            Text(
              document == null
                  ? 'Turn CSV rows into a live local kanban board.'
                  : '${document.fileName} • Live sync on',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Center(child: _SyncStatusPill(status: state.syncStatus)),
          ),
          TextButton.icon(
            onPressed: _pickCsv,
            icon: const Icon(Icons.folder_open_outlined),
            label: const Text('Open CSV'),
          ),
          if (document != null)
            TextButton.icon(
              onPressed: () => _openMappingDialog(document),
              icon: const Icon(Icons.tune_outlined),
              label: const Text('Map Fields'),
            ),
          const SizedBox(width: 8),
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: FilledButton.icon(
              key: const ValueKey('save-document'),
              onPressed: canSave ? _saveDocument : null,
              icon: state.isSaving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      state.syncStatus == BoardSyncStatus.error
                          ? Icons.refresh_outlined
                          : Icons.save_outlined,
                    ),
              label: Text(
                state.syncStatus == BoardSyncStatus.error ? 'Retry Save' : 'Save Now',
              ),
            ),
          ),
        ],
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFFF7F2E8), Color(0xFFE9E4D7)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          top: false,
          child: state.isLoading
              ? const Center(child: CircularProgressIndicator())
              : document == null
                  ? _EmptyBoardState(
                      recentFiles: state.recentFiles,
                      onOpenPressed: _pickCsv,
                      onOpenRecent: (path) {
                        ref.read(boardControllerProvider.notifier).openFile(path);
                      },
                    )
                  : _buildDocumentView(context, state, document),
        ),
      ),
    );
  }

  Widget _buildDocumentView(
    BuildContext context,
    BoardState state,
    BoardDocument document,
  ) {
    final controller = ref.read(boardControllerProvider.notifier);
    final mapping = document.mapping;
    if (mapping == null) {
      return _MappingRequiredState(onMapFields: () => _openMappingDialog(document));
    }

    final wideLayout = MediaQuery.sizeOf(context).width >= 1280;
    final columns = controller.buildColumns();
    final selectedRecord = _selectedRecord(document, state.selectedRecordId);

    Widget buildBoardArea() {
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: ConstrainedBox(
                constraints: BoxConstraints(minWidth: constraints.maxWidth),
                child: SizedBox(
                  height: constraints.maxHeight,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (var index = 0; index < columns.length; index++) ...[
                        SizedBox(
                          width: 320,
                          child: _BoardColumnView(
                            column: columns[index],
                            columnIndex: index,
                            totalColumns: columns.length,
                            mapping: mapping,
                            selectedRecordId: state.selectedRecordId,
                            onCreateCard: () => _createCard(initialStatus: columns[index].name),
                            onMoveLeft: () => controller.moveColumn(columns[index].name, -1),
                            onMoveRight: () => controller.moveColumn(columns[index].name, 1),
                            onRenameColumn: () => _renameColumn(columns[index].name),
                            onDropCard: (recordId) {
                              controller.moveRecord(recordId, columns[index].name);
                            },
                            onOpenRecord: (record) {
                              controller.selectRecord(record.id);
                              if (!wideLayout) {
                                _openRecordEditor(record);
                              }
                            },
                          ),
                        ),
                        const SizedBox(width: 16),
                      ],
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('board-filter'),
                  onChanged: controller.setFilter,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    labelText: 'Filter cards',
                    hintText: 'Search any field value',
                  ),
                ),
              ),
              const SizedBox(width: 16),
              OutlinedButton.icon(
                onPressed: _addColumn,
                icon: const Icon(Icons.view_column_outlined),
                label: const Text('Add Column'),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                onPressed: _createCard,
                icon: const Icon(Icons.add_task_outlined),
                label: const Text('New Card'),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Wrap(
            spacing: 16,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                '${document.records.length} row${document.records.length == 1 ? '' : 's'} loaded',
              ),
              Text(_syncDetailText(state)),
              if (document.lastSavedAt != null)
                Text('Last local save ${_formatTimestamp(document.lastSavedAt!)}'),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Expanded(
          child: wideLayout
              ? Row(
                  children: [
                    Expanded(child: buildBoardArea()),
                    SizedBox(
                      width: 380,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(0, 0, 24, 24),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.85),
                            borderRadius: BorderRadius.circular(28),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(20),
                            child: selectedRecord == null
                                ? const Center(
                                    child: Text('Select a card to edit every CSV field.'),
                                  )
                                : RecordEditor(
                                    title: selectedRecord.read(mapping.titleColumn),
                                    headers: document.headers,
                                    initialValues: selectedRecord.values,
                                    mapping: mapping,
                                    submitLabel: 'Apply changes',
                                    onSubmit: (values) {
                                      controller.applyRecordValues(selectedRecord.id, values);
                                    },
                                    onCancel: () => controller.selectRecord(null),
                                  ),
                          ),
                        ),
                      ),
                    ),
                  ],
                )
              : buildBoardArea(),
        ),
      ],
    );
  }

  BoardRecord? _selectedRecord(BoardDocument document, String? recordId) {
    if (recordId == null) {
      return null;
    }
    for (final record in document.records) {
      if (record.id == recordId) {
        return record;
      }
    }
    return null;
  }

  Future<void> _pickCsv() async {
    final pickerResult = await ref.read(csvFilePickerServiceProvider).pickCsvPath();
    if (!mounted) {
      return;
    }
    final path = pickerResult.launchedPicker
        ? pickerResult.path
        : await showDialog<String>(
            context: context,
            builder: (context) => const CsvPathDialog(),
          );
    if (path == null || path.isEmpty) {
      return;
    }
    await ref.read(boardControllerProvider.notifier).openFile(path);
  }

  Future<void> _saveDocument() async {
    await ref.read(boardControllerProvider.notifier).saveDocument();
  }

  Future<void> _openMappingDialog(BoardDocument document) async {
    final mapping = await showDialog<CsvColumnMapping>(
      context: context,
      builder: (context) => MappingDialog(
        headers: document.headers,
        initialMapping: document.mapping,
      ),
    );
    if (mapping == null) {
      return;
    }
    await ref.read(boardControllerProvider.notifier).applyMapping(mapping);
  }

  Future<void> _createCard({String? initialStatus}) async {
    final controller = ref.read(boardControllerProvider.notifier);
    final recordId = controller.createCard(initialStatus: initialStatus);
    final document = ref.read(boardControllerProvider).document;
    if (document == null) {
      return;
    }
    final record = _selectedRecord(document, recordId);
    if (record != null && MediaQuery.sizeOf(context).width < 1280) {
      await _openRecordEditor(record);
    }
  }

  Future<void> _openRecordEditor(BoardRecord record) async {
    final document = ref.read(boardControllerProvider).document;
    final mapping = document?.mapping;
    if (document == null || mapping == null) {
      return;
    }

    final updatedValues = await showDialog<Map<String, String>>(
      context: context,
      builder: (context) => Dialog(
        child: SizedBox(
          width: 620,
          height: 720,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: RecordEditor(
              title: record.read(mapping.titleColumn),
              headers: document.headers,
              initialValues: record.values,
              mapping: mapping,
              submitLabel: 'Apply changes',
              onCancel: () => Navigator.of(context).pop(),
              onSubmit: (values) => Navigator.of(context).pop(values),
            ),
          ),
        ),
      ),
    );
    if (updatedValues != null) {
      ref.read(boardControllerProvider.notifier).applyRecordValues(record.id, updatedValues);
    }
  }

  Future<void> _addColumn() async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) => const ColumnNameDialog(
        title: 'Add column',
        confirmLabel: 'Add',
      ),
    );
    if (name != null && name.isNotEmpty) {
      ref.read(boardControllerProvider.notifier).addColumn(name);
    }
  }

  Future<void> _renameColumn(String currentName) async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) => ColumnNameDialog(
        title: 'Rename column',
        confirmLabel: 'Rename',
        initialValue: currentName,
      ),
    );
    if (name != null && name.isNotEmpty) {
      ref.read(boardControllerProvider.notifier).renameColumn(currentName, name);
    }
  }

  String _formatTimestamp(DateTime timestamp) {
    final hour = timestamp.hour == 0
        ? 12
        : (timestamp.hour > 12 ? timestamp.hour - 12 : timestamp.hour);
    final minute = timestamp.minute.toString().padLeft(2, '0');
    final suffix = timestamp.hour >= 12 ? 'PM' : 'AM';
    return '$hour:$minute $suffix';
  }

  String _syncDetailText(BoardState state) {
    switch (state.syncStatus) {
      case BoardSyncStatus.idle:
        return 'Live sync is watching for CSV updates.';
      case BoardSyncStatus.saving:
        return 'Saving board changes to the CSV...';
      case BoardSyncStatus.reloading:
        return 'Reloading the CSV from disk...';
      case BoardSyncStatus.externalUpdate:
        return 'The CSV changed outside OpenBoard.';
      case BoardSyncStatus.error:
        return 'Live sync hit an error. Retry save or wait for the next file update.';
    }
  }
}

class _EmptyBoardState extends StatelessWidget {
  const _EmptyBoardState({
    required this.recentFiles,
    required this.onOpenPressed,
    required this.onOpenRecent,
  });

  final List<String> recentFiles;
  final VoidCallback onOpenPressed;
  final ValueChanged<String> onOpenRecent;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.82),
            borderRadius: BorderRadius.circular(32),
          ),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'CSV planning without the spreadsheet drag',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 12),
                const Text(
                  'Open a CSV, map the fields that matter, and work with the rows as draggable kanban cards.',
                ),
                const SizedBox(height: 16),
                const Text(
                  'OpenBoard now watches the CSV for outside edits and writes its own committed changes back automatically.',
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: onOpenPressed,
                  icon: const Icon(Icons.folder_open_outlined),
                  label: const Text('Open CSV'),
                ),
                if (recentFiles.isNotEmpty) ...[
                  const SizedBox(height: 28),
                  Text(
                    'Recent files',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      for (final file in recentFiles)
                        ActionChip(
                          label: Text(file.replaceAll('\\', '/').split('/').last),
                          onPressed: () => onOpenRecent(file),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MappingRequiredState extends StatelessWidget {
  const _MappingRequiredState({required this.onMapFields});

  final VoidCallback onMapFields;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 540),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.82),
            borderRadius: BorderRadius.circular(28),
          ),
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.tune_outlined, size: 40),
                const SizedBox(height: 12),
                Text(
                  'Map the CSV before editing',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                const Text(
                  'OpenBoard needs a title column and a status column before it can build kanban lanes.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: onMapFields,
                  icon: const Icon(Icons.tune_outlined),
                  label: const Text('Map Fields'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SyncStatusPill extends StatelessWidget {
  const _SyncStatusPill({required this.status});

  final BoardSyncStatus status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (label, background, foreground) = switch (status) {
      BoardSyncStatus.idle => ('Live sync on', scheme.primaryContainer, scheme.onPrimaryContainer),
      BoardSyncStatus.saving => ('Saving', scheme.secondaryContainer, scheme.onSecondaryContainer),
      BoardSyncStatus.reloading => ('Reloading', scheme.secondaryContainer, scheme.onSecondaryContainer),
      BoardSyncStatus.externalUpdate => ('Updated', const Color(0xFFF5E4D6), scheme.onSurface),
      BoardSyncStatus.error => ('Sync error', scheme.errorContainer, scheme.onErrorContainer),
    };

    return DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Text(
          label,
          key: const ValueKey('sync-status-pill'),
          style: TextStyle(
            color: foreground,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _BoardColumnView extends StatelessWidget {
  const _BoardColumnView({
    required this.column,
    required this.columnIndex,
    required this.totalColumns,
    required this.mapping,
    required this.selectedRecordId,
    required this.onCreateCard,
    required this.onMoveLeft,
    required this.onMoveRight,
    required this.onRenameColumn,
    required this.onDropCard,
    required this.onOpenRecord,
  });

  final BoardColumn column;
  final int columnIndex;
  final int totalColumns;
  final CsvColumnMapping mapping;
  final String? selectedRecordId;
  final VoidCallback onCreateCard;
  final VoidCallback onMoveLeft;
  final VoidCallback onMoveRight;
  final VoidCallback onRenameColumn;
  final ValueChanged<String> onDropCard;
  final ValueChanged<BoardRecord> onOpenRecord;

  @override
  Widget build(BuildContext context) {
    return DragTarget<_BoardDragData>(
      key: ValueKey('column:${column.name}'),
      onWillAcceptWithDetails: (details) => details.data.originColumn != column.name,
      onAcceptWithDetails: (details) => onDropCard(details.data.recordId),
      builder: (context, candidates, rejected) {
        final highlighted = candidates.isNotEmpty;
        return DecoratedBox(
          decoration: BoxDecoration(
            color: highlighted ? const Color(0xFFF5E4D6) : Colors.white.withValues(alpha: 0.82),
            borderRadius: BorderRadius.circular(28),
            border: Border.all(
              color: highlighted
                  ? Theme.of(context).colorScheme.secondary
                  : Colors.black12,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(column.name, style: Theme.of(context).textTheme.titleLarge),
                          Text('${column.records.length} cards'),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: columnIndex > 0 ? onMoveLeft : null,
                      icon: const Icon(Icons.arrow_back_outlined),
                      tooltip: 'Move column left',
                    ),
                    IconButton(
                      onPressed: columnIndex < totalColumns - 1 ? onMoveRight : null,
                      icon: const Icon(Icons.arrow_forward_outlined),
                      tooltip: 'Move column right',
                    ),
                    IconButton(
                      onPressed: onCreateCard,
                      icon: const Icon(Icons.add_circle_outline),
                      tooltip: 'Add card',
                    ),
                    PopupMenuButton<String>(
                      onSelected: (value) {
                        if (value == 'rename') {
                          onRenameColumn();
                        }
                      },
                      itemBuilder: (context) => const [
                        PopupMenuItem(value: 'rename', child: Text('Rename column')),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: ListView.separated(
                    itemCount: column.records.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 12),
                    itemBuilder: (context, index) {
                      final record = column.records[index];
                      return LongPressDraggable<_BoardDragData>(
                        data: _BoardDragData(
                          recordId: record.id,
                          originColumn: column.name,
                        ),
                        feedback: SizedBox(
                          width: 280,
                          child: Material(
                            color: Colors.transparent,
                            child: _BoardCard(
                              record: record,
                              mapping: mapping,
                              isSelected: false,
                              compact: true,
                              onTap: () {},
                            ),
                          ),
                        ),
                        childWhenDragging: Opacity(
                          opacity: 0.35,
                          child: _BoardCard(
                            record: record,
                            mapping: mapping,
                            isSelected: selectedRecordId == record.id,
                            onTap: () => onOpenRecord(record),
                          ),
                        ),
                        child: _BoardCard(
                          record: record,
                          mapping: mapping,
                          isSelected: selectedRecordId == record.id,
                          onTap: () => onOpenRecord(record),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _BoardCard extends StatelessWidget {
  const _BoardCard({
    required this.record,
    required this.mapping,
    required this.isSelected,
    required this.onTap,
    this.compact = false,
  });

  final BoardRecord record;
  final CsvColumnMapping mapping;
  final bool isSelected;
  final VoidCallback onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: isSelected ? const Color(0xFFEAF4F3) : Colors.white,
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        key: ValueKey('card:${record.id}'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                record.read(mapping.titleColumn).trim().isEmpty
                    ? 'Untitled card'
                    : record.read(mapping.titleColumn),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              if (mapping.descriptionColumn != null &&
                  record.read(mapping.descriptionColumn!).trim().isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  record.read(mapping.descriptionColumn!),
                  maxLines: compact ? 2 : 4,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              if (mapping.extraVisibleColumns.isNotEmpty) ...[
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final header in mapping.extraVisibleColumns)
                      if (record.read(header).trim().isNotEmpty)
                        Chip(label: Text('$header: ${record.read(header)}')),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _BoardDragData {
  const _BoardDragData({required this.recordId, required this.originColumn});

  final String recordId;
  final String originColumn;
}
