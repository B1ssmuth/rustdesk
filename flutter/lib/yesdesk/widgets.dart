import 'package:flutter/material.dart';

import 'theme.dart';

class YesDeskPanel extends StatelessWidget {
  const YesDeskPanel({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = YesDeskColors.of(context);
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(YesDeskSpace.radius),
      side: BorderSide(color: colors.outline),
    );

    return Material(
      color: colors.surface,
      shape: shape,
      child: Padding(
        padding: const EdgeInsets.all(YesDeskSpace.md),
        child: child,
      ),
    );
  }
}

class YesDeskIconButton extends StatelessWidget {
  const YesDeskIconButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.selected = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool selected;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: label,
        child: TextButton(
          onPressed: onPressed,
          style: TextButton.styleFrom(
            backgroundColor:
                selected ? YesDeskColors.of(context).selected : null,
            foregroundColor: selected
                ? YesDeskColors.of(context).accent
                : YesDeskColors.of(context).muted,
            minimumSize: const Size(40, 40),
            padding: const EdgeInsets.all(YesDeskSpace.sm),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: Icon(icon, size: 17, semanticLabel: label),
        ),
      );
}

class YesDeskNavItem extends StatelessWidget {
  const YesDeskNavItem({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.compact,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final bool compact;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = YesDeskColors.of(context);
    return Semantics(
      selected: selected,
      child: Tooltip(
        message: label,
        child: TextButton(
          onPressed: onPressed,
          style: TextButton.styleFrom(
            backgroundColor: selected ? colors.selected : null,
            foregroundColor: selected ? colors.accent : colors.muted,
            disabledBackgroundColor: selected ? colors.selected : null,
            disabledForegroundColor: selected ? colors.accent : colors.muted,
            minimumSize: const Size(0, 42),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            padding: const EdgeInsets.symmetric(
              horizontal: YesDeskSpace.sm,
              vertical: YesDeskSpace.xs,
            ),
          ),
          child: Row(
            mainAxisAlignment:
                compact ? MainAxisAlignment.center : MainAxisAlignment.start,
            children: [
              Icon(icon, size: 17, semanticLabel: compact ? label : null),
              if (!compact) ...[
                const SizedBox(width: YesDeskSpace.sm),
                Flexible(
                    child: Text(label,
                        maxLines: 1, overflow: TextOverflow.ellipsis)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class YesDeskCredential extends StatelessWidget {
  const YesDeskCredential({
    super.key,
    required this.label,
    required this.value,
    required this.copyLabel,
    required this.onCopy,
    this.actions = const [],
  });

  final String label;
  final String value;
  final String copyLabel;
  final VoidCallback? onCopy;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final controls = [
      if (onCopy != null)
        YesDeskIconButton(
          label: copyLabel,
          icon: Icons.content_copy_outlined,
          onPressed: onCopy,
        ),
      ...actions,
    ];
    final display = onCopy == null
        ? Text(value, style: text.titleSmall)
        : SelectableText(
            value,
            style: text.titleMedium?.copyWith(
              fontSize: 18,
              fontFeatures: YesDeskTheme.numericFeatures,
            ),
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: text.bodySmall),
        const SizedBox(height: YesDeskSpace.xs),
        LayoutBuilder(
          builder: (context, constraints) {
            final valueWidth = MediaQuery.textScalerOf(context).scale(112);
            final inline =
                constraints.maxWidth >= valueWidth + 40 * controls.length;
            return Flex(
              direction: inline ? Axis.horizontal : Axis.vertical,
              mainAxisSize: inline ? MainAxisSize.max : MainAxisSize.min,
              crossAxisAlignment: inline
                  ? CrossAxisAlignment.center
                  : CrossAxisAlignment.stretch,
              children: [
                Flexible(flex: inline ? 1 : 0, child: display),
                if (controls.isNotEmpty)
                  Wrap(alignment: WrapAlignment.end, children: controls),
              ],
            );
          },
        ),
      ],
    );
  }
}

class YesDeskQuickConnect extends StatelessWidget {
  const YesDeskQuickConnect({
    super.key,
    required this.title,
    required this.connectLabel,
    required this.field,
    required this.onConnect,
    required this.help,
    required this.actions,
  });

  final String title;
  final String connectLabel;
  final Widget field;
  final VoidCallback? onConnect;
  final Widget help;
  final Widget actions;

  @override
  Widget build(BuildContext context) {
    return YesDeskPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child:
                    Text(title, style: Theme.of(context).textTheme.titleLarge),
              ),
              help,
            ],
          ),
          const SizedBox(height: YesDeskSpace.sm),
          LayoutBuilder(
            builder: (context, constraints) {
              final button = ElevatedButton(
                onPressed: onConnect,
                child: Text(connectLabel, textAlign: TextAlign.center),
              );
              final inline = constraints.maxWidth >=
                  MediaQuery.textScalerOf(context).scale(360);
              final buttons = Row(
                mainAxisSize: inline ? MainAxisSize.min : MainAxisSize.max,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (inline) button else Flexible(child: button),
                  const SizedBox(width: YesDeskSpace.xs),
                  actions,
                ],
              );
              // Keep the input in a stable subtree when the window is resized.
              return Flex(
                direction: inline ? Axis.horizontal : Axis.vertical,
                crossAxisAlignment: inline
                    ? CrossAxisAlignment.center
                    : CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(flex: inline ? 1 : 0, child: field),
                  SizedBox(
                      width: inline ? YesDeskSpace.sm : 0,
                      height: inline ? 0 : YesDeskSpace.sm),
                  buttons,
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

/// Keep the main workspace mounted while opening the support panel at a narrow
/// window size. In wide windows both panes are available at the same time.
class YesDeskWorkspaceLayout extends StatelessWidget {
  const YesDeskWorkspaceLayout({
    super.key,
    required this.main,
    required this.support,
    required this.showSupport,
    required this.header,
  });

  static const wideWidth = 1040.0;

  final Widget main;
  final Widget support;
  final bool showSupport;
  final Widget Function(bool compact) header;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < wideWidth;
        final sideWidth = compact
            ? constraints.maxWidth
            : (constraints.maxWidth * .24).clamp(260.0, 312.0);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            header(compact),
            const Divider(height: 1),
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(
                    right: compact ? 0 : sideWidth + 1,
                    child: Visibility(
                      visible: !compact || !showSupport,
                      maintainState: true,
                      child: main,
                    ),
                  ),
                  if (!compact)
                    Positioned(
                      top: 0,
                      bottom: 0,
                      right: sideWidth,
                      child: const VerticalDivider(width: 1),
                    ),
                  Positioned(
                    top: 0,
                    bottom: 0,
                    right: 0,
                    width: sideWidth,
                    child: Visibility(
                      visible: !compact || showSupport,
                      maintainState: true,
                      child: support,
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Shared column geometry for the desktop device table and its header.
class YesDeskDeviceRow extends StatelessWidget {
  const YesDeskDeviceRow({
    super.key,
    required this.name,
    required this.id,
    required this.platform,
    required this.status,
    this.detail = '',
    this.leading,
    this.action,
    this.header = false,
  });

  final String name;
  final String id;
  final String platform;
  final String status;
  final String detail;
  final Widget? leading;
  final Widget? action;
  final bool header;

  static bool showColumns(BuildContext context, double width) =>
      width >= MediaQuery.textScalerOf(context).scale(570);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    final colors = YesDeskColors.of(context);
    final style = header ? theme.bodySmall : theme.bodyMedium;
    Widget cell(String value) =>
        Text(value, style: style, maxLines: 1, overflow: TextOverflow.ellipsis);

    return LayoutBuilder(builder: (context, constraints) {
      final columns = showColumns(context, constraints.maxWidth);
      final secondary = [if (!columns) id, if (detail.isNotEmpty) detail]
          .where((part) => part.isNotEmpty)
          .join(' · ');
      return Ink(
        decoration: BoxDecoration(
          color: header ? colors.raised : colors.surface,
          border: Border(bottom: BorderSide(color: colors.outline)),
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: header ? 36 : 50),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: YesDeskSpace.md,
              vertical: YesDeskSpace.xs,
            ),
            child: Row(children: [
              Expanded(
                flex: 4,
                child: Row(children: [
                  if (leading != null) ...[
                    leading!,
                    const SizedBox(width: YesDeskSpace.sm),
                  ],
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        cell(name),
                        if (!header && secondary.isNotEmpty)
                          Text(secondary,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.bodySmall),
                      ],
                    ),
                  ),
                ]),
              ),
              if (columns) ...[
                const SizedBox(width: YesDeskSpace.sm),
                Expanded(flex: 2, child: cell(id)),
                const SizedBox(width: YesDeskSpace.sm),
                Expanded(flex: 2, child: cell(platform)),
              ],
              const SizedBox(width: YesDeskSpace.sm),
              Expanded(flex: columns ? 2 : 3, child: cell(status)),
              SizedBox(width: 40, child: action),
            ]),
          ),
        ),
      );
    });
  }
}
