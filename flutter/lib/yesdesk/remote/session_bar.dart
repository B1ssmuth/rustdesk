import 'package:flutter/material.dart';

import '../theme.dart';

/// Chrome shared by the expanded toolbar and the compact restore handle.
class YesDeskSessionBar extends StatefulWidget {
  const YesDeskSessionBar({
    super.key,
    required this.controls,
    required this.windowActions,
    this.status,
  });

  final List<Widget> controls;
  final List<Widget> windowActions;
  final Widget? status;

  @override
  State<YesDeskSessionBar> createState() => _YesDeskSessionBarState();
}

class _YesDeskSessionBarState extends State<YesDeskSessionBar> {
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controls = widget.controls;
    final status = widget.status;
    final colors = YesDeskColors.of(context);
    final radius = BorderRadius.circular(YesDeskSpace.radius);
    return Material(
      color: colors.surface,
      elevation: 4,
      borderRadius: radius,
      clipBehavior: Clip.antiAlias,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: YesDeskSpace.xs),
        decoration: BoxDecoration(
          borderRadius: radius,
          border: Border.all(color: colors.outline),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (controls.isNotEmpty || status != null)
              Flexible(
                child: Scrollbar(
                  controller: _scrollController,
                  thumbVisibility: true,
                  child: SingleChildScrollView(
                    controller: _scrollController,
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (status != null) ...[
                          status,
                          if (controls.isNotEmpty) _divider(colors),
                        ],
                        ...controls,
                      ],
                    ),
                  ),
                ),
              ),
            if (controls.isNotEmpty || status != null) _divider(colors),
            ...widget.windowActions,
          ],
        ),
      ),
    );
  }

  Widget _divider(YesDeskColors colors) => Container(
        width: 1,
        height: 20,
        margin: const EdgeInsets.symmetric(horizontal: YesDeskSpace.xs),
        color: colors.outline,
      );
}

class SessionBarAction extends StatelessWidget {
  const SessionBarAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.selected = false,
    this.showLabel = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool selected;
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    final colors = YesDeskColors.of(context);
    if (showLabel) {
      return Tooltip(
        message: label,
        child: TextButton.icon(
          onPressed: onPressed,
          style: TextButton.styleFrom(
            foregroundColor: selected ? colors.onAccent : colors.text,
            backgroundColor: selected ? colors.accent : null,
            visualDensity: VisualDensity.compact,
          ),
          icon: Icon(icon, size: 17),
          label: Text(label),
        ),
      );
    }
    return IconButton(
      tooltip: label,
      onPressed: onPressed,
      visualDensity: VisualDensity.compact,
      iconSize: 19,
      color: colors.text,
      icon: Icon(icon),
    );
  }
}

class SessionBarStatus extends StatelessWidget {
  const SessionBarStatus({
    super.key,
    required this.label,
    this.details = const [],
    this.metrics = const [],
  });

  final String label;
  final List<String> metrics;
  final List<String> details;

  @override
  Widget build(BuildContext context) {
    final colors = YesDeskColors.of(context);
    return Tooltip(
      message: [label, ...details].join('\n'),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: YesDeskSpace.sm),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.network_check, size: 18, color: colors.muted),
            const SizedBox(width: YesDeskSpace.sm),
            Text(
              metrics.isEmpty ? label : metrics.join('  ·  '),
              style: TextStyle(
                color: colors.text,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                fontFeatures: YesDeskTheme.numericFeatures,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
