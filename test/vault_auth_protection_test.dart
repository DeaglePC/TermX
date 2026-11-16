import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termx/core/models/host_config.dart';
import 'package:termx/core/vault/vault_service.dart';
import 'package:termx/ui/widgets/dialogs_and_sheets.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const savedHost = HostConfig(
    id: 'host_prod_01',
    name: 'Prod-Gateway',
    group: '生产环境',
    host: '192.168.31.62',
    port: 22,
    username: 'root',
    authMethod: AuthMethod.password,
  );

  Future<VaultService> createTestVaultWithSecret(String password) async {
    final vault = VaultService()..debugStorageOverride = <String, String>{};
    await vault.saveCredential(
      savedHost,
      HostSecretCredential(
        password: password,
        updatedAt: DateTime(2026, 11, 15),
      ),
    );
    return vault;
  }

  Future<void> setViewport(WidgetTester tester, Size size) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = size;
    await tester.binding.setSurfaceSize(size);
  }

  Future<void> resetViewport(WidgetTester tester) async {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    await tester.binding.setSurfaceSize(null);
  }

  testWidgets('编辑已保存密码的主机时默认加密锁定，验证失败不暴露明文，验证通过后才解密展示', (tester) async {
    await setViewport(tester, const Size(1280, 900));
    addTearDown(() => resetViewport(tester));

    const secretPwd = 'MySuperSecret#2026';
    final vault = await createTestVaultWithSecret(secretPwd);
    var shouldPassAuth = false;
    vault.debugAuthOverride = (_) async {
      return shouldPassAuth
          ? const VaultAuthResult(VaultAuthOutcome.authenticated)
          : const VaultAuthResult(VaultAuthOutcome.canceled, '已取消身份验证');
    };

    HostConfig? savedConfig;
    HostSecretCredential? savedSecret;

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: ElevatedButton(
                onPressed: () {
                  unawaited(
                    showHostFormDialog(
                      context: ctx,
                      existingHost: savedHost,
                      vaultService: vault,
                      hasSavedCredential: true,
                      onSave: (h, s) async {
                        savedConfig = h;
                        savedSecret = s;
                      },
                    ),
                  );
                },
                child: const Text('打开编辑'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开编辑'));
    await tester.pumpAndSettle();

    // 1. 刚打开编辑弹窗时，明文密码绝不出现在任何输入框或文本节点中
    expect(find.textContaining('SSH 登录密码已加密保存'), findsOneWidget);
    expect(find.text('验证身份查看'), findsOneWidget);
    expect(find.text(secretPwd), findsNothing);
    for (final tf in tester.widgetList<TextField>(find.byType(TextField))) {
      expect(tf.controller?.text, isNot(equals(secretPwd)));
    }

    // 2. 第一次点击「验证身份查看」，模拟用户取消指纹/人脸验证 -> 仍保持锁定，不暴露明文
    await tester.tap(find.text('验证身份查看'));
    await tester.pumpAndSettle();

    expect(find.textContaining('仍处于加密锁定状态'), findsOneWidget);
    expect(find.text(secretPwd), findsNothing);

    // 3. 第二次点击「验证身份查看」，模拟指纹/人脸/系统密码验证通过 -> 解密并直接展示明文密码
    shouldPassAuth = true;
    await tester.tap(find.text('验证身份查看'));
    await tester.pumpAndSettle();

    expect(find.textContaining('SSH 登录密码已加密保存'), findsNothing);
    expect(find.text(secretPwd), findsOneWidget);

    await tester.tap(find.text('保存修改'));
    await tester.pumpAndSettle();

    expect(savedConfig?.name, 'Prod-Gateway');
    expect(savedSecret?.password, secretPwd);
  });

  testWidgets('未解锁原密码直接修改主机信息保存时，自动完整保留原加密密码；也支持直接覆盖新密码', (tester) async {
    await setViewport(tester, const Size(1280, 900));
    addTearDown(() => resetViewport(tester));

    const originalPwd = 'KeepMeIntact!888';
    final vault = await createTestVaultWithSecret(originalPwd);

    HostConfig? savedConfig;
    HostSecretCredential? savedSecret;

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: ElevatedButton(
                onPressed: () {
                  unawaited(
                    showHostFormDialog(
                      context: ctx,
                      existingHost: savedHost,
                      vaultService: vault,
                      hasSavedCredential: true,
                      onSave: (h, s) async {
                        savedConfig = h;
                        savedSecret = s;
                      },
                    ),
                  );
                },
                child: const Text('打开编辑'),
              ),
            ),
          ),
        ),
      ),
    );

    // 场景 A：不点验证查看，只把主机别名改成 Prod-Gateway-V2 后保存 -> 原密码完整保留
    await tester.tap(find.text('打开编辑'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'Prod-Gateway'),
      'Prod-Gateway-V2',
    );
    await tester.tap(find.text('保存修改'));
    await tester.pumpAndSettle();

    expect(savedConfig?.name, 'Prod-Gateway-V2');
    expect(savedSecret?.password, originalPwd);

    // 场景 B：不查看原密码，直接点「更改密码」输入新密码覆盖
    await tester.tap(find.text('打开编辑'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('更改密码'));
    await tester.pumpAndSettle();

    expect(find.text(originalPwd), findsNothing);
    expect(find.text('取消更改（保留原保存密码）'), findsOneWidget);
    expect(find.text('输入新的 SSH 登录密码（保存后覆盖原密码）'), findsOneWidget);

    final newPwdField = find.byKey(const Key('host_form_password_input'));
    expect(newPwdField, findsOneWidget);
    await tester.enterText(newPwdField, 'RotatedNewPass!99');
    await tester.tap(find.text('保存修改'));
    await tester.pumpAndSettle();

    expect(savedSecret?.password, 'RotatedNewPass!99');
  });

  testWidgets('SSH 编辑弹窗在 PC 宽屏与窄屏分辨率下均无布局溢出', (tester) async {
    addTearDown(() => resetViewport(tester));
    final vault = await createTestVaultWithSecret('LayoutCheck#2026');

    for (final size in const [
      Size(1440, 900),
      Size(1280, 800),
      Size(420, 840),
    ]) {
      await setViewport(tester, size);

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: Builder(
              builder: (ctx) => Center(
                child: ElevatedButton(
                  onPressed: () {
                    unawaited(
                      showHostFormDialog(
                        context: ctx,
                        existingHost: savedHost,
                        vaultService: vault,
                        hasSavedCredential: true,
                        onDelete: (_) async {},
                        onSave: (_, _) async {},
                      ),
                    );
                  },
                  child: const Text('测试布局'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('测试布局'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }

    await tester.binding.setSurfaceSize(null);
  });
}
