import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import 'ui_tokens.dart';

/// 三态自适应窗口模式
enum AdaptiveLayoutMode {
  compact,
  medium,
  expanded,
}

/// 窗口布局形态切换
enum FormFactorOverride {
  auto('自动响应'),
  desktop('桌面布局'),
  ipad('平板布局'),
  phone('紧凑布局');

  final String label;
  const FormFactorOverride(this.label);
}

class AdaptiveBreakpoints {
  static AdaptiveLayoutMode resolve(
    double width,
    FormFactorOverride override,
  ) {
    switch (override) {
      case FormFactorOverride.desktop:
        return AdaptiveLayoutMode.expanded;
      case FormFactorOverride.ipad:
        return width < 640
            ? AdaptiveLayoutMode.compact
            : AdaptiveLayoutMode.medium;
      case FormFactorOverride.phone:
        return AdaptiveLayoutMode.compact;
      case FormFactorOverride.auto:
        if (width < 640) return AdaptiveLayoutMode.compact;
        if (width < 1020) return AdaptiveLayoutMode.medium;
        return AdaptiveLayoutMode.expanded;
    }
  }
}

/// 终端配色主题定义（克制、耐看的专业终端色板）
class TermXColorPalette {
  final String id;
  final String name;
  final TerminalTheme terminalTheme;
  final Color accentColor;
  final Color surfaceColor;

  const TermXColorPalette({
    required this.id,
    required this.name,
    required this.terminalTheme,
    required this.accentColor,
    required this.surfaceColor,
  });

  static const List<TermXColorPalette> presets = [
    TermXColorPalette(
      id: 'graphite_studio',
      name: '石墨碳黑 (默认)',
      accentColor: TxColors.accent,
      surfaceColor: TxColors.bgSidebar,
      terminalTheme: TerminalTheme(
        cursor: Color(0xFFD5DAE2),
        selection: Color(0x523B82F6),
        foreground: Color(0xFFE3E6EC),
        background: Color(0xFF13161B),
        black: Color(0xFF1B1F27),
        red: Color(0xFFE56B6F),
        green: Color(0xFF56C271),
        yellow: Color(0xFFD9A557),
        blue: Color(0xFF5C9DFF),
        magenta: Color(0xFFB38BF5),
        cyan: Color(0xFF4AB8C4),
        white: Color(0xFFC9CFD9),
        brightBlack: Color(0xFF565E6D),
        brightRed: Color(0xFFF08083),
        brightGreen: Color(0xFF6FD387),
        brightYellow: Color(0xFFE7B96E),
        brightBlue: Color(0xFF79B0FF),
        brightMagenta: Color(0xFFC5A5FA),
        brightCyan: Color(0xFF66CCD6),
        brightWhite: Color(0xFFF3F5F8),
        searchHitBackground: Color(0xFFD29922),
        searchHitBackgroundCurrent: Color(0xFF4C8DFF),
        searchHitForeground: Color(0xFF0D0F12),
      ),
    ),
    TermXColorPalette(
      id: 'macos_pro',
      name: '深空纯灰 (Pro Dark)',
      accentColor: Color(0xFF0A84FF),
      surfaceColor: Color(0xFF161618),
      terminalTheme: TerminalTheme(
        cursor: Color(0xFFE5E5EA),
        selection: Color(0x550A84FF),
        foreground: Color(0xFFE5E5EA),
        background: Color(0xFF1B1B1D),
        black: Color(0xFF1C1C1E),
        red: Color(0xFFFF6961),
        green: Color(0xFF4CD964),
        yellow: Color(0xFFFFD60A),
        blue: Color(0xFF409CFF),
        magenta: Color(0xFFBF5AF2),
        cyan: Color(0xFF5AC8FA),
        white: Color(0xFFD1D1D6),
        brightBlack: Color(0xFF636366),
        brightRed: Color(0xFFFF8078),
        brightGreen: Color(0xFF6CE380),
        brightYellow: Color(0xFFFFDF40),
        brightBlue: Color(0xFF66B2FF),
        brightMagenta: Color(0xFFD182F7),
        brightCyan: Color(0xFF7DD6FC),
        brightWhite: Color(0xFFFFFFFF),
        searchHitBackground: Color(0xFFD29922),
        searchHitBackgroundCurrent: Color(0xFF0A84FF),
        searchHitForeground: Color(0xFF111113),
      ),
    ),
    TermXColorPalette(
      id: 'nordic_slate',
      name: '极地灰蓝 (Nord)',
      accentColor: Color(0xFF88C0D0),
      surfaceColor: Color(0xFF1E222A),
      terminalTheme: TerminalTheme(
        cursor: Color(0xFFD8DEE9),
        selection: Color(0x554C566A),
        foreground: Color(0xFFD8DEE9),
        background: Color(0xFF242933),
        black: Color(0xFF2E3440),
        red: Color(0xFFBF616A),
        green: Color(0xFFA3BE8C),
        yellow: Color(0xFFEBCB8B),
        blue: Color(0xFF81A1C1),
        magenta: Color(0xFFB48EAD),
        cyan: Color(0xFF88C0D0),
        white: Color(0xFFE5E9F0),
        brightBlack: Color(0xFF59647A),
        brightRed: Color(0xFFD08770),
        brightGreen: Color(0xFFA3BE8C),
        brightYellow: Color(0xFFEBCB8B),
        brightBlue: Color(0xFF81A1C1),
        brightMagenta: Color(0xFFB48EAD),
        brightCyan: Color(0xFF8FBCBB),
        brightWhite: Color(0xFFECEFF4),
        searchHitBackground: Color(0xFFEBCB8B),
        searchHitBackgroundCurrent: Color(0xFF88C0D0),
        searchHitForeground: Color(0xFF242933),
      ),
    ),
    TermXColorPalette(
      id: 'warm_espresso',
      name: '暖调深咖 (护眼暗色)',
      accentColor: Color(0xFFD4976C),
      surfaceColor: Color(0xFF161413),
      terminalTheme: TerminalTheme(
        cursor: Color(0xFFE6DDD3),
        selection: Color(0x556B5344),
        foreground: Color(0xFFE6DDD3),
        background: Color(0xFF1B1918),
        black: Color(0xFF242120),
        red: Color(0xFFDC6F68),
        green: Color(0xFF8EB872),
        yellow: Color(0xFFD9A760),
        blue: Color(0xFF7CA4BC),
        magenta: Color(0xFFC28BA8),
        cyan: Color(0xFF7DB6A3),
        white: Color(0xFFD5C9BC),
        brightBlack: Color(0xFF665E57),
        brightRed: Color(0xFFE8867F),
        brightGreen: Color(0xFFA3C989),
        brightYellow: Color(0xFFE6BA7A),
        brightBlue: Color(0xFF94B8CE),
        brightMagenta: Color(0xFFD3A3BC),
        brightCyan: Color(0xFF96C8B7),
        brightWhite: Color(0xFFF5EFE8),
        searchHitBackground: Color(0xFFD9A760),
        searchHitBackgroundCurrent: Color(0xFFD4976C),
        searchHitForeground: Color(0xFF1B1918),
      ),
    ),
    TermXColorPalette(
      id: 'tokyo_night',
      name: '东京夜色 (Classic)',
      accentColor: Color(0xFF6D9BF0),
      surfaceColor: Color(0xFF13151C),
      terminalTheme: TerminalTheme(
        cursor: Color(0xFFC0CAF5),
        selection: Color(0x6633467C),
        foreground: Color(0xFFC0CAF5),
        background: Color(0xFF171922),
        black: Color(0xFF15161E),
        red: Color(0xFFF7768E),
        green: Color(0xFF9ECE6A),
        yellow: Color(0xFFE0AF68),
        blue: Color(0xFF7AA2F7),
        magenta: Color(0xFFBB9AF7),
        cyan: Color(0xFF7DCFFF),
        white: Color(0xFFA9B1D6),
        brightBlack: Color(0xFF414868),
        brightRed: Color(0xFFF7768E),
        brightGreen: Color(0xFF9ECE6A),
        brightYellow: Color(0xFFE0AF68),
        brightBlue: Color(0xFF7AA2F7),
        brightMagenta: Color(0xFFBB9AF7),
        brightCyan: Color(0xFF7DCFFF),
        brightWhite: Color(0xFFC0CAF5),
        searchHitBackground: Color(0xFFE0AF68),
        searchHitBackgroundCurrent: Color(0xFFFF9E64),
        searchHitForeground: Color(0xFF15161E),
      ),
    ),
  ];
}
