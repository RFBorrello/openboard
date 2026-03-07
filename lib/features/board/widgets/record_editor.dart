import 'package:flutter/material.dart';

import '../../../core/models/board_models.dart';

class RecordEditor extends StatefulWidget {
  const RecordEditor({
    super.key,
    required this.title,
    required this.headers,
    required this.initialValues,
    required this.mapping,
    required this.onSubmit,
    this.onCancel,
    this.submitLabel = 'Save changes',
  });

  final String title;
  final List<String> headers;
  final Map<String, String> initialValues;
  final CsvColumnMapping? mapping;
  final ValueChanged<Map<String, String>> onSubmit;
  final VoidCallback? onCancel;
  final String submitLabel;

  @override
  State<RecordEditor> createState() => _RecordEditorState();
}

class _RecordEditorState extends State<RecordEditor> {
  late final Map<String, TextEditingController> _controllers;

  @override
  void initState() {
    super.initState();
    _controllers = {
      for (final header in widget.headers)
        header: TextEditingController(text: widget.initialValues[header] ?? ''),
    };
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.title, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          Text(
            'Edit every CSV column in one place. Unmapped columns are preserved on save.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          Expanded(
            child: ListView.separated(
              itemCount: widget.headers.length,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final header = widget.headers[index];
                final label = widget.mapping?.labelForHeader(header);
                return TextField(
                  controller: _controllers[header],
                  minLines: header == widget.mapping?.descriptionColumn ? 4 : 1,
                  maxLines: header == widget.mapping?.descriptionColumn ? 6 : 1,
                  decoration: InputDecoration(
                    labelText: header,
                    helperText: label,
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              if (widget.onCancel != null)
                TextButton(
                  onPressed: widget.onCancel,
                  child: const Text('Cancel'),
                ),
              const Spacer(),
              FilledButton.icon(
                onPressed: () {
                  widget.onSubmit({
                    for (final entry in _controllers.entries)
                      entry.key: entry.value.text,
                  });
                },
                icon: const Icon(Icons.save_outlined),
                label: Text(widget.submitLabel),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
