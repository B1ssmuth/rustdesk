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
    required this.online,
    required this.offline,
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
  final Color online;
  final Color offline;
  final Color error;

  static const light = YesDeskColors(
    canvas: Color(0xFFF5F5F5),
    surface: Color(0xFFFFFFFF),
    raised: Color(0xFFEAEAEA),
    outline: Color(0xFFD9D9D9),
    text: Color(0xFF171717),
    muted: Color(0xFF666666),
    accent: Color(0xFF171717),
    onAccent: Color(0xFFFFFFFF),
    selected: Color(0xFFEAEAEA),
    warning: Color(0xFF805300),
    error: Color(0xFFA72727),
    online: Color(0xFF136237),
    offline: Color(0xFFA72727),
  );

  static const dark = YesDeskColors(
    canvas: Color(0xFF101010),
    surface: Color(0xFF1C1C1C),
    raised: Color(0xFF292929),
    outline: Color(0xFF363636),
    text: Color(0xFFFFFFFF),
    muted: Color(0xFFA3A3A3),
    accent: Color(0xFFFFFFFF),
    onAccent: Color(0xFF111111),
    selected: Color(0xFF292929),
    warning: Color(0xFFF7C66F),
    error: Color(0xFFFFA0A0),
    online: Color(0xFF79DCA7),
    offline: Color(0xFFFFA0A0),
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
      online: Color.lerp(online, other.online, t)!,
      offline: Color.lerp(offline, other.offline, t)!,
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
    if (base.extension<YesDeskColors>() != null) return child;
    return Theme(data: apply(base), child: child);
  }

  static ThemeData apply(ThemeData base) {
    if (base.extension<YesDeskColors>() != null) return base;
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

    return base.copyWith(
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
      dialogTheme: DialogTheme(
        backgroundColor: colors.surface,
        elevation: 12,
        shape: shape.copyWith(side: BorderSide(color: colors.outline)),
      ),
      cardTheme: CardTheme(
        color: colors.surface,
        elevation: 0,
        shape: shape.copyWith(side: BorderSide(color: colors.outline)),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: colors.surface,
          border: Border.all(color: colors.outline),
          borderRadius: BorderRadius.circular(YesDeskSpace.radius),
        ),
        textStyle: TextStyle(color: colors.text, fontSize: 12),
      ),
      dividerTheme: DividerThemeData(color: colors.outline, thickness: 1),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: colors.surface,
        contentTextStyle: TextStyle(color: colors.text),
        shape: shape,
      ),
      listTileTheme: base.listTileTheme.copyWith(
        textColor: colors.text,
        iconColor: colors.muted,
        selectedColor: colors.accent,
        selectedTileColor: colors.selected,
      ),
      checkboxTheme: base.checkboxTheme.copyWith(
        fillColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected) ? colors.accent : null),
        checkColor: WidgetStatePropertyAll(colors.onAccent),
      ),
      radioTheme: base.radioTheme.copyWith(
        fillColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected) ? colors.accent : null),
      ),
      switchTheme: base.switchTheme.copyWith(
        thumbColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected) ? colors.accent : null),
        trackColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected) ? colors.outline : null),
      ),
      dividerColor: colors.outline,
      hintColor: colors.muted,
      primaryColor: colors.accent,
      splashColor: colors.accent.withOpacity(.14),
      focusColor: colors.selected,
      hoverColor: colors.raised,
      iconTheme: base.iconTheme.copyWith(color: colors.muted),
      tabBarTheme: base.tabBarTheme.copyWith(
        labelColor: colors.text,
        unselectedLabelColor: colors.muted,
        indicatorColor: colors.accent,
      ),
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
        labelStyle: TextStyle(color: colors.muted),
        floatingLabelStyle: TextStyle(color: colors.accent),
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
          minimumSize: const Size(0, 40),
          shape: shape,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: colors.text,
          minimumSize: const Size(0, 40),
          side: BorderSide(color: colors.outline),
          shape: shape,
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: colors.surface,
        shape: shape.copyWith(side: BorderSide(color: colors.outline)),
      ),
    );
  }
}
