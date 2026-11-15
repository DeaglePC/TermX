import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/models/remote_os.dart';
import '../../core/ssh/ssh_session_controller.dart';
import 'terminal_pane_view.dart';

/// 操作系统品牌矢量 Logo 图标（纯 Canvas 矢量绘制，任意字号与高分屏清晰无锯齿）
class OsLogoIcon extends StatelessWidget {
  const OsLogoIcon({
    super.key,
    required this.os,
    this.size = 15,
    this.tooltip,
  });

  final RemoteOsType os;
  final double size;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final Widget icon = os == RemoteOsType.unknown
        ? Icon(
            Icons.dns_rounded,
            size: size,
            color: const Color(0xFF7DCFFF),
          )
        : SizedBox(
            width: size,
            height: size,
            child: CustomPaint(
              painter: _OsLogoPainter(os),
            ),
          );
    if (tooltip != null && tooltip!.isNotEmpty) {
      return Tooltip(message: tooltip!, child: icon);
    }
    return icon;
  }
}

/// 会话连接状态 + 自动识别系统 Logo 组合微件（用于顶部标签栏与分屏标题栏）
class SessionOsStatusBadge extends StatelessWidget {
  const SessionOsStatusBadge({
    super.key,
    required this.session,
    this.size = 15,
    this.badgeBorderColor = const Color(0xFF24283B),
  });

  final SshSessionController session;
  final double size;
  final Color badgeBorderColor;

  String _stateLabel(SessionConnectionState state) => switch (state) {
    SessionConnectionState.connected => '已连接',
    SessionConnectionState.connecting => '连接中…',
    SessionConnectionState.reconnecting => '重连中…',
    SessionConnectionState.disconnected => '已断开',
    SessionConnectionState.error => '连接异常',
  };

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final state = session.state;
        final os = session.detectedOs;
        final dotColor = connectionColor(state);
        final osTitle = session.detectedOsPrettyName ??
            (os != RemoteOsType.unknown ? os.displayName : '远程主机');
        final tooltip = '$osTitle · ${_stateLabel(state)}';

        if (os == RemoteOsType.unknown) {
          final dotSize = (size * 0.54).clamp(7.0, 9.0);
          return Tooltip(
            message: tooltip,
            child: SizedBox(
              width: dotSize,
              height: dotSize,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: dotColor,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          );
        }

        final isConnected = state == SessionConnectionState.connected;
        final isDisconnected = state == SessionConnectionState.disconnected;

        Widget icon = OsLogoIcon(os: os, size: size);
        if (isDisconnected) {
          icon = Opacity(opacity: 0.85, child: icon);
        }

        if (!isConnected) {
          final badgeSize = (size * 0.46).clamp(6.0, 7.5);
          icon = SizedBox(
            width: size + 2,
            height: size + 2,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Align(alignment: Alignment.center, child: icon),
                Positioned(
                  right: -1,
                  bottom: -1,
                  child: Container(
                    width: badgeSize,
                    height: badgeSize,
                    decoration: BoxDecoration(
                      color: dotColor,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: badgeBorderColor,
                        width: 1.3,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        }

        return Tooltip(
          message: tooltip,
          child: icon,
        );
      },
    );
  }
}

class _OsLogoPainter extends CustomPainter {
  const _OsLogoPainter(this.os);

  final RemoteOsType os;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    canvas.save();
    canvas.scale(size.width / 24.0, size.height / 24.0);
    switch (os) {
      case RemoteOsType.ubuntu:
        _paintUbuntu(canvas);
      case RemoteOsType.centos:
        _paintCentos(canvas);
      case RemoteOsType.raspberryPi:
        _paintRaspberryPi(canvas);
      case RemoteOsType.macos:
        _paintApple(canvas);
      case RemoteOsType.linux:
        _paintLinuxTux(canvas);
      case RemoteOsType.debian:
        _paintDebian(canvas);
      case RemoteOsType.fedora:
        _paintFedora(canvas);
      case RemoteOsType.redhat:
        _paintRedHat(canvas);
      case RemoteOsType.rocky:
        _paintRocky(canvas);
      case RemoteOsType.alma:
        _paintAlma(canvas);
      case RemoteOsType.arch:
        _paintArch(canvas);
      case RemoteOsType.alpine:
        _paintAlpine(canvas);
      case RemoteOsType.opensuse:
        _paintOpenSuse(canvas);
      case RemoteOsType.freebsd:
        _paintFreeBsd(canvas);
      case RemoteOsType.windows:
        _paintWindows(canvas);
      case RemoteOsType.unknown:
        break;
    }
    canvas.restore();
  }

  /// Ubuntu Circle of Friends 经典橙底白环三人牵手徽标
  void _paintUbuntu(Canvas canvas) {
    const center = Offset(12, 12);
    const orange = Color(0xFFE95420);
    final bgPaint = Paint()..color = orange;
    final whiteFill = Paint()..color = Colors.white;

    canvas.drawCircle(center, 11.2, bgPaint);

    // 白色圆环（在 0°、120°、240° 留出牵手缝隙）
    final ringPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.55
      ..strokeCap = StrokeCap.butt;

    final ringRect = Rect.fromCircle(center: center, radius: 5.75);
    const gapRad = 0.24;
    for (final baseDeg in [-60.0, 60.0, 180.0]) {
      final mid = baseDeg * math.pi / 180.0;
      const halfSpan = math.pi / 3.0 - gapRad;
      canvas.drawArc(ringRect, mid - halfSpan, halfSpan * 2, false, ringPaint);
    }

    // 三个外圈圆点（左 180°、右上 -60°、右下 +60°），带橙色外圈镂空
    for (final deg in [180.0, -60.0, 60.0]) {
      final rad = deg * math.pi / 180.0;
      final headCenter = Offset(
        center.dx + math.cos(rad) * 8.05,
        center.dy + math.sin(rad) * 8.05,
      );
      canvas.drawCircle(headCenter, 2.55, bgPaint);
      canvas.drawCircle(headCenter, 1.72, whiteFill);
    }
  }

  /// CentOS 经典四色交错菱形/方格徽标
  void _paintCentos(Canvas canvas) {
    const c = Offset(12, 12);
    const yellow = Color(0xFFEFA724);
    const green = Color(0xFF9CCD2A);
    const blue = Color(0xFF4C6EF5);
    const purple = Color(0xFFB5389E);

    final borderPaint = Paint()
      ..color = const Color(0xFF16161E)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.85
      ..strokeJoin = StrokeJoin.round;

    // 四个底层正交方格
    const sq = 6.8;
    final squares = <(Rect, Color)>[
      (Rect.fromLTRB(c.dx - sq, c.dy - sq, c.dx, c.dy), green),
      (Rect.fromLTRB(c.dx, c.dy - sq, c.dx + sq, c.dy), purple),
      (Rect.fromLTRB(c.dx, c.dy, c.dx + sq, c.dy + sq), yellow),
      (Rect.fromLTRB(c.dx - sq, c.dy, c.dx, c.dy + sq), blue),
    ];
    for (final (rect, color) in squares) {
      canvas.drawRect(rect, Paint()..color = color);
      canvas.drawRect(rect, borderPaint);
    }

    // 四个 45° 旋转菱形箭头（上黄、右绿、下蓝、左紫）
    const tip = 11.0;
    const wing = 4.85;
    final diamonds = <(List<Offset>, Color)>[
      (
        [
          c,
          Offset(c.dx - wing, c.dy - tip + wing),
          Offset(c.dx, c.dy - tip),
          Offset(c.dx + wing, c.dy - tip + wing),
        ],
        yellow,
      ),
      (
        [
          c,
          Offset(c.dx + tip - wing, c.dy - wing),
          Offset(c.dx + tip, c.dy),
          Offset(c.dx + tip - wing, c.dy + wing),
        ],
        green,
      ),
      (
        [
          c,
          Offset(c.dx + wing, c.dy + tip - wing),
          Offset(c.dx, c.dy + tip),
          Offset(c.dx - wing, c.dy + tip - wing),
        ],
        blue,
      ),
      (
        [
          c,
          Offset(c.dx - tip + wing, c.dy + wing),
          Offset(c.dx - tip, c.dy),
          Offset(c.dx - tip + wing, c.dy - wing),
        ],
        purple,
      ),
    ];

    for (final (pts, color) in diamonds) {
      final p = Path()..addPolygon(pts, true);
      canvas.drawPath(p, Paint()..color = color);
      canvas.drawPath(p, borderPaint);
    }
  }

  /// 树莓派 (Raspberry Pi) 双绿叶 + 浆果分瓣徽标
  void _paintRaspberryPi(Canvas canvas) {
    final leafPaint = Paint()..color = const Color(0xFF75B82A);
    final berryBase = Paint()..color = const Color(0xFFC51A4A);
    final berryLobe = Paint()..color = const Color(0xFFE31C58);
    final sepStroke = Paint()
      ..color = const Color(0xFF2B0A16)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.9;

    // 左绿叶与右绿叶
    final leftLeaf = Path()
      ..moveTo(11.7, 6.6)
      ..cubicTo(10.8, 3.0, 7.6, 1.4, 5.2, 2.2)
      ..cubicTo(5.6, 5.0, 8.2, 6.8, 11.7, 6.6)
      ..close();
    final rightLeaf = Path()
      ..moveTo(12.3, 6.6)
      ..cubicTo(13.2, 3.0, 16.4, 1.4, 18.8, 2.2)
      ..cubicTo(18.4, 5.0, 15.8, 6.8, 12.3, 6.6)
      ..close();
    canvas.drawPath(leftLeaf, leafPaint);
    canvas.drawPath(rightLeaf, leafPaint);

    // 浆果底色轮廓
    canvas.drawOval(const Rect.fromLTWH(4.6, 6.6, 14.8, 15.4), berryBase);

    // 树莓颗粒分瓣（外圈 + 中心颗粒）
    const drupelets = <(double, double, double)>[
      (8.3, 10.0, 2.85),
      (15.7, 10.0, 2.85),
      (12.0, 9.2, 2.75),
      (6.9, 14.3, 2.95),
      (17.1, 14.3, 2.95),
      (8.8, 18.4, 2.85),
      (15.2, 18.4, 2.85),
      (12.0, 20.0, 2.55),
      (12.0, 14.3, 3.25),
    ];
    for (final (x, y, r) in drupelets) {
      final center = Offset(x, y);
      canvas.drawCircle(center, r, berryLobe);
      canvas.drawCircle(center, r, sepStroke);
    }
  }

  /// macOS 经典 Apple 咬口苹果矢量剪影
  void _paintApple(Canvas canvas) {
    final paint = Paint()..color = const Color(0xFFF2F4F8);

    // 顶部右侧倾斜苹果叶
    final leaf = Path()
      ..moveTo(12.0, 5.8)
      ..cubicTo(12.1, 3.4, 14.0, 1.6, 16.2, 1.4)
      ..cubicTo(16.3, 3.8, 14.4, 5.7, 12.0, 5.8)
      ..close();
    canvas.drawPath(leaf, paint);

    // 苹果主体轮廓
    final body = Path()
      ..moveTo(12.0, 7.3)
      ..cubicTo(13.7, 7.3, 15.0, 6.1, 16.8, 6.1)
      ..cubicTo(18.8, 6.1, 20.4, 7.3, 21.1, 9.1)
      ..cubicTo(21.4, 15.0, 18.7, 21.8, 15.8, 21.8)
      ..cubicTo(14.5, 21.8, 13.7, 21.0, 12.0, 21.0)
      ..cubicTo(10.3, 21.0, 9.5, 21.8, 8.2, 21.8)
      ..cubicTo(5.3, 21.8, 2.8, 15.0, 3.2, 10.2)
      ..cubicTo(3.5, 7.5, 5.5, 6.1, 7.5, 6.1)
      ..cubicTo(9.3, 6.1, 10.6, 7.3, 12.0, 7.3)
      ..close();

    // 右侧标志性圆弧咬口差集
    final bite = Path()
      ..addOval(Rect.fromCircle(center: const Offset(21.5, 12.3), radius: 3.45));
    final appleBody = Path.combine(PathOperation.difference, body, bite);
    canvas.drawPath(appleBody, paint);
  }

  /// Linux 经典 Tux 企鹅矢量图标（高对比白肚皮 + 金黄嘴脚 + 浅色轮廓适配深色背景）
  void _paintLinuxTux(Canvas canvas) {
    final bodyFill = Paint()..color = const Color(0xFF202534);
    final rimStroke = Paint()
      ..color = const Color(0xFFD8DEE9)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1;
    final whiteFill = Paint()..color = Colors.white;
    final yellowFill = Paint()..color = const Color(0xFFFFB300);

    // 企鹅头与梨形身体轮廓
    final silhouette = Path()
      ..moveTo(12.0, 1.8)
      ..cubicTo(8.5, 1.8, 6.8, 4.2, 6.8, 7.4)
      ..cubicTo(6.8, 9.3, 4.4, 11.8, 4.4, 15.6)
      ..cubicTo(4.4, 19.2, 7.4, 21.4, 12.0, 21.4)
      ..cubicTo(16.6, 21.4, 19.6, 19.2, 19.6, 15.6)
      ..cubicTo(19.6, 11.8, 17.2, 9.3, 17.2, 7.4)
      ..cubicTo(17.2, 4.2, 15.5, 1.8, 12.0, 1.8)
      ..close();
    canvas.drawPath(silhouette, bodyFill);
    canvas.drawPath(silhouette, rimStroke);

    // 白色圆肚皮
    canvas.drawOval(
      const Rect.fromLTWH(7.3, 10.0, 9.4, 10.2),
      whiteFill,
    );

    // 双眼与瞳孔
    canvas.drawOval(const Rect.fromLTWH(8.4, 4.7, 3.1, 3.8), whiteFill);
    canvas.drawOval(const Rect.fromLTWH(12.5, 4.7, 3.1, 3.8), whiteFill);
    canvas.drawCircle(const Offset(10.3, 6.7), 0.95, bodyFill);
    canvas.drawCircle(const Offset(13.7, 6.7), 0.95, bodyFill);

    // 金黄色企鹅喙
    final beak = Path()
      ..moveTo(9.0, 8.5)
      ..quadraticBezierTo(12.0, 7.6, 15.0, 8.5)
      ..quadraticBezierTo(12.0, 11.3, 9.0, 8.5)
      ..close();
    canvas.drawPath(beak, yellowFill);

    // 金黄色脚蹼
    canvas.drawOval(const Rect.fromLTWH(5.2, 19.3, 5.2, 3.0), yellowFill);
    canvas.drawOval(const Rect.fromLTWH(13.6, 19.3, 5.2, 3.0), yellowFill);
  }

  /// Debian 经典酒红漩涡
  void _paintDebian(Canvas canvas) {
    final paint = Paint()
      ..color = const Color(0xFFE11D48)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.35
      ..strokeCap = StrokeCap.round;

    final spiral = Path();
    const steps = 46;
    for (var i = 0; i <= steps; i++) {
      final t = i / steps;
      final angle = -math.pi * 0.4 + t * math.pi * 3.25;
      final radius = 1.6 + t * 8.8;
      final pt = Offset(
        12.4 + math.cos(angle) * radius,
        11.8 + math.sin(angle) * radius,
      );
      if (i == 0) {
        spiral.moveTo(pt.dx, pt.dy);
      } else {
        spiral.lineTo(pt.dx, pt.dy);
      }
    }
    canvas.drawPath(spiral, paint);
  }

  /// Fedora 蓝底白 f 徽标
  void _paintFedora(Canvas canvas) {
    canvas.drawCircle(
      const Offset(12, 12),
      11.0,
      Paint()..color = const Color(0xFF3C6EB4),
    );
    final stroke = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round;

    final fPath = Path()
      ..moveTo(9.2, 17.5)
      ..cubicTo(11.2, 17.5, 12.2, 16.2, 12.2, 13.8)
      ..lineTo(12.2, 8.8)
      ..cubicTo(12.2, 6.8, 13.5, 5.8, 15.4, 5.8)
      ..moveTo(8.8, 12.0)
      ..lineTo(15.2, 12.0);
    canvas.drawPath(fPath, stroke);
  }

  /// Red Hat 经典红帽徽标
  void _paintRedHat(Canvas canvas) {
    final red = Paint()..color = const Color(0xFFEE0000);
    final band = Paint()..color = const Color(0xFF1A1B26);

    // 帽檐
    canvas.save();
    canvas.translate(12, 15.2);
    canvas.rotate(0.12);
    canvas.drawOval(
      Rect.fromCenter(center: Offset.zero, width: 21.5, height: 6.6),
      red,
    );
    canvas.restore();

    // 帽冠
    final crown = Path()
      ..moveTo(5.2, 14.0)
      ..cubicTo(5.8, 8.2, 8.2, 5.5, 10.6, 6.2)
      ..cubicTo(11.8, 6.5, 12.6, 7.2, 14.0, 6.0)
      ..cubicTo(16.2, 4.8, 18.2, 8.4, 18.4, 14.4)
      ..close();
    canvas.drawPath(crown, red);

    // 黑色帽带
    final ribbon = Path()
      ..moveTo(5.1, 13.0)
      ..quadraticBezierTo(11.8, 15.4, 18.5, 13.8)
      ..lineTo(18.3, 15.3)
      ..quadraticBezierTo(11.7, 16.9, 5.0, 14.4)
      ..close();
    canvas.drawPath(ribbon, band);
  }

  /// Rocky Linux 翠绿山峰圆章
  void _paintRocky(Canvas canvas) {
    final circle = Path()
      ..addOval(Rect.fromCircle(center: const Offset(12, 12), radius: 11.0));
    final peak = Path()
      ..moveTo(5.0, 22.5)
      ..lineTo(15.2, 11.2)
      ..lineTo(22.5, 18.5)
      ..lineTo(19.5, 22.5)
      ..close();
    final combined = Path.combine(PathOperation.difference, circle, peak);
    canvas.drawPath(combined, Paint()..color = const Color(0xFF10B981));
  }

  /// AlmaLinux 四彩花瓣徽标
  void _paintAlma(Canvas canvas) {
    const colors = [
      Color(0xFFEF4444),
      Color(0xFFF59E0B),
      Color(0xFF10B981),
      Color(0xFF3B82F6),
    ];
    for (var i = 0; i < 4; i++) {
      canvas.save();
      canvas.translate(12, 12);
      canvas.rotate(i * math.pi / 2);
      canvas.drawOval(
        const Rect.fromLTWH(-3.0, -10.5, 6.0, 8.6),
        Paint()..color = colors[i],
      );
      canvas.restore();
    }
  }

  /// Arch Linux 经典尖峰拱门剪影
  void _paintArch(Canvas canvas) {
    final triangle = Path()
      ..moveTo(12.0, 2.0)
      ..lineTo(21.4, 21.2)
      ..quadraticBezierTo(16.8, 19.4, 12.0, 19.2)
      ..quadraticBezierTo(7.2, 19.4, 2.6, 21.2)
      ..close();
    final archCut = Path()
      ..addOval(const Rect.fromLTWH(8.7, 13.6, 6.6, 10.5));
    final arch = Path.combine(PathOperation.difference, triangle, archCut);
    canvas.drawPath(arch, Paint()..color = const Color(0xFF1793D1));
  }

  /// Alpine Linux 蓝底双雪峰
  void _paintAlpine(Canvas canvas) {
    final hex = Path();
    for (var i = 0; i < 6; i++) {
      final a = -math.pi / 2 + i * math.pi / 3;
      final pt = Offset(12 + math.cos(a) * 11.0, 12 + math.sin(a) * 11.0);
      if (i == 0) {
        hex.moveTo(pt.dx, pt.dy);
      } else {
        hex.lineTo(pt.dx, pt.dy);
      }
    }
    hex.close();
    canvas.drawPath(hex, Paint()..color = const Color(0xFF0D597F));

    final mountain = Path()
      ..moveTo(4.6, 16.4)
      ..lineTo(9.8, 8.2)
      ..lineTo(13.2, 13.5)
      ..lineTo(15.6, 10.0)
      ..lineTo(19.6, 16.4)
      ..close();
    canvas.drawPath(mountain, Paint()..color = Colors.white);
  }

  /// openSUSE 翠绿圆弧卷尾徽标
  void _paintOpenSuse(Canvas canvas) {
    canvas.drawCircle(
      const Offset(12, 12),
      10.8,
      Paint()..color = const Color(0xFF73BA25),
    );
    final stroke = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      Rect.fromCircle(center: const Offset(11.5, 12.5), radius: 5.2),
      -math.pi * 0.8,
      math.pi * 1.45,
      false,
      stroke,
    );
    canvas.drawCircle(
      const Offset(15.2, 9.2),
      1.5,
      Paint()..color = Colors.white,
    );
  }

  /// FreeBSD 经典红色小恶魔角圆球
  void _paintFreeBsd(Canvas canvas) {
    final red = Paint()..color = const Color(0xFFEF4444);
    canvas.drawCircle(const Offset(12, 13), 8.8, red);
    final leftHorn = Path()
      ..moveTo(5.6, 8.2)
      ..quadraticBezierTo(2.4, 3.2, 6.2, 2.2)
      ..quadraticBezierTo(6.8, 5.4, 9.2, 6.2)
      ..close();
    final rightHorn = Path()
      ..moveTo(18.4, 8.2)
      ..quadraticBezierTo(21.6, 3.2, 17.8, 2.2)
      ..quadraticBezierTo(17.2, 5.4, 14.8, 6.2)
      ..close();
    canvas.drawPath(leftHorn, red);
    canvas.drawPath(rightHorn, red);
  }

  /// Microsoft Windows 经典四格蓝窗
  void _paintWindows(Canvas canvas) {
    final paint = Paint()..color = const Color(0xFF00A4EF);
    const r = Radius.circular(1.1);
    canvas.drawRRect(
      RRect.fromRectAndRadius(const Rect.fromLTWH(2.6, 2.6, 8.5, 8.5), r),
      paint,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(const Rect.fromLTWH(12.9, 2.6, 8.5, 8.5), r),
      paint,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(const Rect.fromLTWH(2.6, 12.9, 8.5, 8.5), r),
      paint,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(const Rect.fromLTWH(12.9, 12.9, 8.5, 8.5), r),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _OsLogoPainter oldDelegate) =>
      oldDelegate.os != os;
}
