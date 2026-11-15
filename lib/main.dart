import 'dart:io';

import 'package:flutter/material.dart';

import 'core/theme/ui_tokens.dart';
import 'ui/termx_workbench.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const TermXApp());
}

class TermXApp extends StatelessWidget {
  const TermXApp({super.key});

  static ThemeData buildDarkTheme() {
    final fontFamily = Platform.isWindows ? 'Microsoft YaHei UI' : null;
    const scheme = ColorScheme.dark(
      primary: TxColors.accent,
      onPrimary: Colors.white,
      secondary: TxColors.textSecondary,
      onSecondary: TxColors.bgChrome,
      surface: TxColors.bgSidebar,
      onSurface: TxColors.textPrimary,
      error: TxColors.danger,
      onError: Colors.white,
      outline: TxColors.borderDefault,
      outlineVariant: TxColors.borderSubtle,
    );

    return ThemeData(
      brightness: Brightness.dark,
      useMaterial3: true,
      fontFamily: fontFamily,
      colorScheme: scheme,
      scaffoldBackgroundColor: TxColors.bgSidebar,
      canvasColor: TxColors.bgElevated,
      dividerColor: TxColors.borderSubtle,
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.white.withValues(alpha: 0.04),
      hoverColor: TxColors.bgHover,
      dividerTheme: const DividerThemeData(
        color: TxColors.borderSubtle,
        thickness: 1,
        space: 1,
      ),
      iconTheme: const IconThemeData(color: TxColors.iconDefault, size: 17),
      cardTheme: CardThemeData(
        color: TxColors.bgPanel,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(7),
          side: const BorderSide(color: TxColors.borderSubtle),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: const Color(0xFF16191F),
        surfaceTintColor: Colors.transparent,
        elevation: 12,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: const BorderSide(color: TxColors.borderDefault),
        ),
        titleTextStyle: TextStyle(
          fontFamily: fontFamily,
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: TxColors.textPrimary,
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: TxColors.bgElevated,
        surfaceTintColor: Colors.transparent,
        elevation: 10,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: TxColors.borderDefault),
        ),
        textStyle: TextStyle(
          fontFamily: fontFamily,
          fontSize: 12.5,
          color: TxColors.textPrimary,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        filled: true,
        fillColor: const Color(0xFF111419),
        labelStyle: const TextStyle(
          fontSize: 12,
          color: TxColors.textSecondary,
        ),
        hintStyle: const TextStyle(fontSize: 12, color: TxColors.textMuted),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 10,
          vertical: 10,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: TxColors.borderDefault),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: TxColors.accent, width: 1.2),
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: TxColors.borderDefault),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: TxColors.accent,
          foregroundColor: Colors.white,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          textStyle: TextStyle(
            fontFamily: fontFamily,
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
          ),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: TxColors.textSecondary,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          textStyle: TextStyle(fontFamily: fontFamily, fontSize: 12.5),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 420),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: const Color(0xFF20252E),
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: TxColors.borderStrong),
        ),
        textStyle: TextStyle(
          fontFamily: fontFamily,
          fontSize: 11.5,
          color: TxColors.textPrimary,
        ),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thickness: WidgetStateProperty.all(5),
        radius: const Radius.circular(3),
        thumbColor: WidgetStateProperty.all(
          Colors.white.withValues(alpha: 0.14),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: TxColors.bgElevated,
        contentTextStyle: TextStyle(
          fontFamily: fontFamily,
          fontSize: 12.5,
          color: TxColors.textPrimary,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(7),
          side: const BorderSide(color: TxColors.borderDefault),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TermX',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: buildDarkTheme(),
      home: const TermXWorkbench(),
    );
  }
}
