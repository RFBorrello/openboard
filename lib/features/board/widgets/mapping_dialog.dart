import 'package:flutter/material.dart';

import '../../../core/models/board_models.dart';

class MappingDialog extends StatefulWidget {
  const MappingDialog({
    super.key,
    required this.headers,
    this.initialMapping,
  });

  final List<String> headers;
  final CsvColumnMapping? initialMapping;

  @override
  State<MappingDialog> createState() => _MappingDialogState();
}

class _MappingDialogState extends State<MappingDialog> {
  static const _none = '__none__';

  late String _titleColumn;
  late String _statusColumn;
  late String? _descriptionColumn;
  late String? _assigneeColumn;
  late String? _dueDateColumn;
  late Set<String> _extraVisibleColumns;
  String? _error;

  @override
  void initState() {
    super.initState();
    _titleColumn = widget.initialMapping?.titleColumn ?? widget.headers.first;
    _statusColumn = widget.initialMapping?.statusColumn ??
        (widget.headers.length > 1 ? widget.headers[1] : widget.headers.first);
    _descriptionColumn = widget.initialMapping?.descriptionColumn;
    _assigneeColumn = widget.initialMapping?.assigneeColumn;
    _dueDateColumn = widget.initialMapping?.dueDateColumn;
    _extraVisibleColumns = {
      ...widget.initialMapping?.extraVisibleColumns ?? const <String>[],
    };
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Map CSV columns'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Choose which CSV columns drive the board and which extra fields should stay visible on cards.',
              ),
              const SizedBox(height: 16),
              _buildDropdown(
                label: 'Title column',
                value: _titleColumn,
                onChanged: (value) => setState(() => _titleColumn = value!),
              ),
              const SizedBox(height: 12),
              _buildDropdown(
                label: 'Status column',
                value: _statusColumn,
                onChanged: (value) => setState(() => _statusColumn = value!),
              ),
              const SizedBox(height: 12),
              _buildDropdown(
                label: 'Description column',
                value: _descriptionColumn ?? _none,
                allowNone: true,
                onChanged: (value) => setState(() {
                  _descriptionColumn = value == _none ? null : value;
                }),
              ),
              const SizedBox(height: 12),
              _buildDropdown(
                label: 'Assignee column',
                value: _assigneeColumn ?? _none,
                allowNone: true,
                onChanged: (value) => setState(() {
                  _assigneeColumn = value == _none ? null : value;
                }),
              ),
              const SizedBox(height: 12),
              _buildDropdown(
                label: 'Due date column',
                value: _dueDateColumn ?? _none,
                allowNone: true,
                onChanged: (value) => setState(() {
                  _dueDateColumn = value == _none ? null : value;
                }),
              ),
              const SizedBox(height: 16),
              Text(
                'Extra card fields',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final header in widget.headers)
                    FilterChip(
                      label: Text(header),
                      selected: _extraVisibleColumns.contains(header),
                      onSelected: _isReserved(header)
                          ? null
                          : (selected) {
                              setState(() {
                                if (selected) {
                                  _extraVisibleColumns.add(header);
                                } else {
                                  _extraVisibleColumns.remove(header);
                                }
                              });
                            },
                    ),
                ],
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Save mapping'),
        ),
      ],
    );
  }

  DropdownButtonFormField<String> _buildDropdown({
    required String label,
    required String value,
    required ValueChanged<String?> onChanged,
    bool allowNone = false,
  }) {
    final items = [
      if (allowNone) const DropdownMenuItem(value: _none, child: Text('None')),
      ...widget.headers.map(
        (header) => DropdownMenuItem(value: header, child: Text(header)),
      ),
    ];
    return DropdownButtonFormField<String>(
      initialValue: value,
      decoration: InputDecoration(labelText: label),
      items: items,
      onChanged: onChanged,
    );
  }

  bool _isReserved(String header) {
    return header == _titleColumn ||
        header == _statusColumn ||
        header == _descriptionColumn ||
        header == _assigneeColumn ||
        header == _dueDateColumn;
  }

  void _submit() {
    if (_titleColumn == _statusColumn) {
      setState(() => _error = 'Title and status need different columns.');
      return;
    }
    final mapping = CsvColumnMapping(
      titleColumn: _titleColumn,
      statusColumn: _statusColumn,
      descriptionColumn: _descriptionColumn,
      assigneeColumn: _assigneeColumn,
      dueDateColumn: _dueDateColumn,
      extraVisibleColumns: _extraVisibleColumns
          .where((header) => !_isReserved(header))
          .toList(growable: false),
    );
    Navigator.of(context).pop(mapping);
  }
}

