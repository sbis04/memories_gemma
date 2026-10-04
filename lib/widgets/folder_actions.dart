import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/app_theme.dart';
import 'focusable.dart';

enum FolderAction { pin, rename, delete }

const _danger = Color(0xFFE5484D);

/// The menu shown when OK is held on a folder: pin/unpin, and — for folders
/// on a real drive — rename and delete. Returns the chosen action, or null.
Future<FolderAction?> showFolderActions(
  BuildContext context, {
  required String name,
  required bool pinned,
  required bool canEdit,
}) {
  return _showPanel<FolderAction>(
    context,
    builder: (context) {
      final c = context.colors;
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Title(name),
          const SizedBox(height: 14),
          _MenuRow(
            icon: pinned ? LucideIcons.pinOff : LucideIcons.pin,
            label: pinned ? 'Unpin' : 'Pin to top',
            autofocus: true,
            onPressed: () => Navigator.of(context).pop(FolderAction.pin),
          ),
          if (canEdit) ...[
            _MenuRow(
              icon: LucideIcons.pencil,
              label: 'Rename',
              onPressed: () => Navigator.of(context).pop(FolderAction.rename),
            ),
            _MenuRow(
              icon: LucideIcons.trash2,
              label: 'Delete',
              color: _danger,
              onPressed: () => Navigator.of(context).pop(FolderAction.delete),
            ),
          ] else
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
              child: Text(
                'Rename and delete are available when browsing the drive '
                'directly.',
                style: TextStyle(color: c.textFaint, fontSize: 13),
              ),
            ),
        ],
      );
    },
  );
}

/// Asks for a new name (prefilled and selected). Returns it, or null.
Future<String?> showRenameDialog(BuildContext context, {required String name}) {
  return showTextInputDialog(context,
      title: 'Rename folder', initial: name, confirmLabel: 'Rename');
}

/// A one-field text dialog (TV keyboard; its mic works too). Returns the
/// trimmed text, or null if cancelled or unchanged.
Future<String?> showTextInputDialog(
  BuildContext context, {
  required String title,
  String initial = '',
  String? hint,
  String confirmLabel = 'Save',
  bool allowSlash = false,
}) {
  return _showPanel<String>(
    context,
    builder: (context) => _TextForm(
      title: title,
      initial: initial,
      hint: hint,
      confirmLabel: confirmLabel,
      allowSlash: allowSlash,
    ),
  );
}

/// Confirms a permanent delete. Cancel has focus so a stray OK is harmless.
Future<bool> showDeleteDialog(
  BuildContext context, {
  required String name,
  required String detail,
}) async {
  final ok = await _showPanel<bool>(
    context,
    builder: (context) {
      final c = context.colors;
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Title('Delete “$name”?'),
          const SizedBox(height: 10),
          Text(
            detail,
            style: TextStyle(color: c.textSecondary, fontSize: 15, height: 1.4),
          ),
          const SizedBox(height: 22),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              _Button(
                label: 'Cancel',
                autofocus: true,
                onPressed: () => Navigator.of(context).pop(false),
              ),
              const SizedBox(width: 12),
              _Button(
                label: 'Delete',
                color: _danger,
                onPressed: () => Navigator.of(context).pop(true),
              ),
            ],
          ),
        ],
      );
    },
  );
  return ok ?? false;
}

Future<T?> _showPanel<T>(BuildContext context,
    {required WidgetBuilder builder}) {
  return showDialog<T>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.6),
    builder: (context) {
      final c = context.colors;
      return Center(
        child: Material(
          type: MaterialType.transparency,
          child: Container(
            width: 460,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: c.surface,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: c.hairline),
              boxShadow: [
                BoxShadow(
                  color: c.shadow.withValues(alpha: 0.5),
                  blurRadius: 40,
                  offset: const Offset(0, 12),
                ),
              ],
            ),
            child: FocusTraversalGroup(child: builder(context)),
          ),
        ),
      );
    },
  );
}

class _Title extends StatelessWidget {
  const _Title(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: context.colors.textPrimary,
        fontSize: 20,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.autofocus = false,
    this.color,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final bool autofocus;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Focusable(
        autofocus: autofocus,
        onPressed: onPressed,
        focusScale: 1.0,
        builder: (context, focused) {
          final fg = focused ? c.onAccent : (color ?? c.textPrimary);
          return AnimatedContainer(
            duration: AppTheme.focusAnim,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
            decoration: BoxDecoration(
              color: focused ? (color ?? c.accent) : Colors.transparent,
              borderRadius: BorderRadius.circular(13),
            ),
            child: Row(
              children: [
                Icon(icon, size: 19, color: fg),
                const SizedBox(width: 14),
                Text(
                  label,
                  style: TextStyle(
                    color: fg,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _Button extends StatelessWidget {
  const _Button({
    required this.label,
    required this.onPressed,
    this.autofocus = false,
    this.color,
  });

  final String label;
  final VoidCallback onPressed;
  final bool autofocus;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Focusable(
      autofocus: autofocus,
      onPressed: onPressed,
      builder: (context, focused) => AnimatedContainer(
        duration: AppTheme.focusAnim,
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 11),
        decoration: BoxDecoration(
          color: focused ? (color ?? c.accent) : c.surfaceHigh,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: focused ? c.onAccent : (color ?? c.textPrimary),
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _TextForm extends StatefulWidget {
  const _TextForm({
    required this.title,
    required this.initial,
    required this.confirmLabel,
    required this.allowSlash,
    this.hint,
  });
  final String title;
  final String initial;
  final String? hint;
  final String confirmLabel;
  final bool allowSlash;

  @override
  State<_TextForm> createState() => _TextFormState();
}

class _TextFormState extends State<_TextForm> {
  late final TextEditingController _text = TextEditingController(
      text: widget.initial)
    ..selection =
        TextSelection(baseOffset: 0, extentOffset: widget.initial.length);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _text.text.trim();
    Navigator.of(context).pop(
        text.isEmpty || text == widget.initial ? null : text);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Title(widget.title),
        const SizedBox(height: 16),
        TextField(
          controller: _text,
          autofocus: true,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _submit(),
          inputFormatters: [
            if (!widget.allowSlash) FilteringTextInputFormatter.deny(RegExp('[/]')),
          ],
          cursorColor: c.accent,
          style: TextStyle(color: c.textPrimary, fontSize: 17),
          decoration: InputDecoration(
            hintText: widget.hint,
            hintStyle: TextStyle(color: c.textFaint),
            filled: true,
            fillColor: c.surfaceHigh,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: c.hairline),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: c.accent, width: 2),
            ),
          ),
        ),
        const SizedBox(height: 22),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            _Button(
              label: 'Cancel',
              onPressed: () => Navigator.of(context).pop(),
            ),
            const SizedBox(width: 12),
            _Button(label: widget.confirmLabel, onPressed: _submit),
          ],
        ),
      ],
    );
  }
}
