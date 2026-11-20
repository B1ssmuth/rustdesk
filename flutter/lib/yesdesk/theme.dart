import 'package:flutter/material.dart';

abstract final class YesDeskSpace {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
  static const radius = 8.0;
}

@immutable
class YesDeskColors extends ThemeExtension<YesDeskColors> {
  const YesDeskColors({
    required this.canvas,
    required this.surface,
    required this.raised,
    required this.outline,
    required this.text,
    required this.muted,
    required this.accent,
    required this.onAccent,
    required this.selected,
    required this.warning,
    required this.error,
  });

  final Color canvas;
  final Color surface;
  final Color raised;
  final Color outline;
  final Color text;
  final Color muted;
  final Color accent;
  final Color onAccent;
  final Color selected;
  final Color warning;
  final Color error;

  static const light = YesDeskColors(
    canvas: Color(0xFFF5F6F3),
    surface: Color(0xFFFFFFFF),
    raised: Color(0xFFEBEEE8),
    outline: Color(0xFFD5DAD2),
    text: Color(0xFF202620),
    muted: Color(0xFF505C53),
    accent: Color(0xFF416217),
    onAccent: Color(0xFFFFFFFF),
    selected: Color(0xFFE6EFD7),
    warning: Color(0xFF854C13),
    error: Color(0xFFAC2F36),
  );

  static const dark = YesDeskColors(
    canvas: Color(0xFF151719),
    surface: Color(0xFF1D2023),
    raised: Color(0xFF292D31),
    outline: Color(0xFF3A4046),
    text: Color(0xFFF2F5EF),
    muted: Color(0xFFABB5AE),
    accent: Color(0xFFB7E879),
    onAccent: Color(0xFF1B2712),
    selected: Color(0xFF2D3926),
    warning: Color(0xFFF1BE75),
    error: Color(0xFFFF9398),
  );

  static YesDeskColors of(BuildContext context) =>
      Theme.of(context).extension<YesDeskColors>()!;

  @override
  YesDeskColors copyWith() => this;

  @override
  YesDeskColors lerp(YesDeskColors? other, double t) {
    if (other == null) return this;
    return YesDeskColors(
      canvas: Color.lerp(canvas, other.canvas, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      raised: Color.lerp(raised, other.raised, t)!,
      outline: Color.lerp(outline, other.outline, t)!,
      text: Color.lerp(text, other.text, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      onAccent: Color.lerp(onAccent, other.onAccent, t)!,
      selected: Color.lerp(selected, other.selected, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      error: Color.lerp(error, other.error, t)!,
    );
  }
}

/// The workspace inherits the system/user theme and the app's legacy
/// extensions so existing peer controls can run inside the same surface.
class YesDeskTheme extends StatelessWidget {
  const YesDeskTheme({super.key, required this.child});

  final Widget child;

  static const numericFeatures = [FontFeature.tabularFigures()];

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context);
    final colors = base.brightness == Brightness.dark
        ? YesDeskColors.dark
        : YesDeskColors.light;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(YesDeskSpace.radius),
    );
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(YesDeskSpace.radius),
      borderSide: BorderSide(color: colors.outline),
    );

    return Theme(
      data: base.copyWith(
        extensions: [...base.extensions.values, colors],
        colorScheme: base.colorScheme.copyWith(
          primary: colors.accent,
          onPrimary: colors.onAccent,
          secondary: colors.accent,
          onSecondary: colors.onAccent,
          surface: colors.surface,
          onSurface: colors.text,
          // Pre-Material 3 peer controls still read the background property.
          // ignore: deprecated_member_use
          background: colors.surface,
          // ignore: deprecated_member_use
          onBackground: colors.text,
          error: colors.error,
        ),
        scaffoldBackgroundColor: colors.canvas,
        canvasColor: colors.surface,
        cardColor: colors.surface,
        dialogBackgroundColor: colors.surface,
        dividerColor: colors.outline,
        hintColor: colors.muted,
        focusColor: colors.selected,
        hoverColor: colors.raised,
        iconTheme: base.iconTheme.copyWith(color: colors.muted),
        tabBarTheme: base.tabBarTheme.copyWith(labelColor: colors.muted),
        textTheme: base.textTheme
            .apply(bodyColor: colors.text, displayColor: colors.text)
            .copyWith(
              titleLarge: TextStyle(
                color: colors.text,
                fontSize: 22,
                fontWeight: FontWeight.w700,
                height: 1.15,
              ),
              titleMedium: TextStyle(
                color: colors.text,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
              titleSmall: TextStyle(color: colors.text, fontSize: 13),
              bodyMedium: TextStyle(color: colors.text, fontSize: 13),
              bodySmall: TextStyle(
                color: colors.muted,
                fontSize: 12,
                height: 1.35,
              ),
              labelLarge: TextStyle(
                color: colors.text,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
        textSelectionTheme: TextSelectionThemeData(
          cursorColor: colors.accent,
          selectionColor: colors.accent.withOpacity(.28),
          selectionHandleColor: colors.accent,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: colors.canvas,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: YesDeskSpace.md,
            vertical: YesDeskSpace.md,
          ),
          hintStyle: TextStyle(color: colors.muted),
          border: border,
          enabledBorder: border,
          focusedBorder: border.copyWith(
            borderSide: BorderSide(color: colors.accent, width: 2),
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            elevation: 0,
            minimumSize: const Size(0, 40),
            backgroundColor: colors.accent,
            foregroundColor: colors.onAccent,
            disabledBackgroundColor: colors.raised,
            disabledForegroundColor: colors.muted,
            shape: shape,
          ).copyWith(
            side: WidgetStateProperty.resolveWith((states) {
              return states.contains(WidgetState.focused)
                  ? BorderSide(color: colors.onAccent, width: 2)
                  : null;
            }),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            foregroundColor: colors.accent,
            minimumSize: const Size(0, 36),
            shape: shape,
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: colors.text,
            minimumSize: const Size(0, 36),
            side: BorderSide(color: colors.outline),
            shape: shape,
          ),
        ),
        popupMenuTheme: PopupMenuThemeData(
          color: colors.surface,
          shape: shape.copyWith(side: BorderSide(color: colors.outline)),
        ),
      ),
      child: child,
    );
  }
}
