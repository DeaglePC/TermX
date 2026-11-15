import 'package:flutter/material.dart';

/// TermX 桌面级中性碳黑设计令牌（去 AI 霓虹感，参考 Zed / Ghostty / Linear / Transmit）
class TxColors {
  TxColors._();

  // 基础层级表面（纯正中性冷炭灰，不含蓝紫荧光底色）
  static const Color bgChrome = Color(0xFF0D0F12); // 顶栏、底栏
  static const Color bgSidebar = Color(0xFF111317); // 左右侧边栏
  static const Color bgCanvas = Color(0xFF14171C); // 默认终端画布背景
  static const Color bgPanel = Color(0xFF16191F); // 面板内卡片/代码块底色
  static const Color bgElevated = Color(0xFF1B1F27); // 激活态标签、菜单、弹窗、输入框
  static const Color bgHover = Color(0xFF1F242D); // 鼠标悬停态
  static const Color bgSelected = Color(0xFF232934); // 列表选中态

  // 1px 精细分割线边框
  static const Color borderSubtle = Color(0xFF1E222B);
  static const Color borderDefault = Color(0xFF282E3A);
  static const Color borderStrong = Color(0xFF363E4D);

  // 文本与图标层级（全界面工具图标默认保持克制的单色灰阶）
  static const Color textPrimary = Color(0xFFE6E9EF);
  static const Color textSecondary = Color(0xFF9BA3B0);
  static const Color textMuted = Color(0xFF666E7D);
  static const Color iconDefault = Color(0xFF8891A0);
  static const Color iconHover = Color(0xFFD5DAE2);

  // 克制的语义色（仅用于真实状态指示、图表与主操作按钮）
  static const Color accent = Color(0xFF4C8DFF);
  static const Color accentSoft = Color(0x244C8DFF);
  static const Color success = Color(0xFF3FB950);
  static const Color warning = Color(0xFFD29922);
  static const Color danger = Color(0xFFE5534B);
  static const Color folderAmber = Color(0xFFC89B54);
  static const Color fileSlate = Color(0xFF8492A6);

  static const String monoFamily = 'Consolas';
}
