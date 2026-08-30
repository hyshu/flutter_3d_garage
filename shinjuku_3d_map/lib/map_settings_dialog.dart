import 'package:flutter/material.dart';

final class const MapSettingsDialog({
  required final bool labelsVisible,
  required final bool labelsEnabled,
  required final Future<bool> Function(bool visible) onLabelsChanged,
  super.key,
}) extends StatefulWidget {
  @override
  State<MapSettingsDialog> createState() => _MapSettingsDialogState();
}

final class _MapSettingsDialogState extends State<MapSettingsDialog> {
  late bool _labelsVisible;
  var _updating = false;

  @override
  void initState() {
    super.initState();
    _labelsVisible = widget.labelsVisible;
  }

  Future<void> _setLabelsVisible(bool visible) async {
    setState(() => _updating = true);
    final updated = await widget.onLabelsChanged(visible);
    if (!mounted) return;
    setState(() {
      if (updated) _labelsVisible = visible;
      _updating = false;
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Map settings'),
    contentPadding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
    content: SwitchListTile(
      title: const Text('Labels'),
      value: _labelsVisible,
      onChanged: !widget.labelsEnabled || _updating ? null : _setLabelsVisible,
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Close'),
      ),
    ],
  );
}
