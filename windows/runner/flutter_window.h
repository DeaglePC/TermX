#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>

#include "win32_window.h"

class Win32FileDropTarget;

// A window that hosts a Flutter view plus native Win32 file I/O & drag-and-drop.
class FlutterWindow : public Win32Window {
 public:
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  void SetupNativeIoChannel();
  void RestoreSavedWindowState();
  void UpdateCachedNormalRect(HWND hwnd) noexcept;
  void PersistWindowState(HWND hwnd) noexcept;

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // MethodChannel for native file dialogs and OLE file drag-and-drop.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      native_io_channel_;

  Win32FileDropTarget* drop_target_ = nullptr;
  HWND drop_target_hwnd_ = nullptr;
  RECT last_normal_rect_ = {0, 0, 0, 0};
  bool has_normal_rect_ = false;
  bool start_maximized_ = false;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
