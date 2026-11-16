#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <ole2.h>
#include <cstdio>

#include "flutter_window.h"
#include "utils.h"

// Force NVIDIA GPU on Optimus / multi-GPU systems
extern "C" {
__declspec(dllexport) DWORD NvOptimusEnablement = 0x00000001;
__declspec(dllexport) int AmdPowerXpressRequestHighPerformance = 1;
}

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run')
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  OutputDebugStringW(L"[TermX] wWinMain entered\n");

  // Initialize OLE & COM STA (required for OLE IDropTarget file drag-and-drop & IFileDialog)
  ::OleInitialize(nullptr);

  flutter::DartProject project(L"data");
  project.set_impeller_switch(flutter::ImpellerSwitch::Disabled);
  project.set_gpu_preference(flutter::GpuPreference::HighPerformancePreference);

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();
  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  OutputDebugStringW(L"[TermX] Creating FlutterWindow...\n");

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);

  OutputDebugStringW(L"[TermX] Calling window.Create...\n");

  if (!window.Create(L"TermX", origin, size)) {
    OutputDebugStringW(L"[TermX] window.Create FAILED!\n");
    MessageBoxW(nullptr, L"Failed to create Flutter window.\nThis may be caused by a GPU driver incompatibility.\nTry updating your NVIDIA drivers.", L"TermX Error", MB_OK | MB_ICONERROR);
    return EXIT_FAILURE;
  }

  OutputDebugStringW(L"[TermX] window.Create succeeded, forcing visibility\n");

  // Force show the window while preserving restored maximized state
  HWND hwnd = window.GetHandle();
  if (hwnd) {
    if (!::IsZoomed(hwnd)) {
      ShowWindow(hwnd, SW_SHOWNORMAL);
    }
    UpdateWindow(hwnd);
    SetForegroundWindow(hwnd);
    BringWindowToTop(hwnd);
  }

  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::OleUninitialize();
  return EXIT_SUCCESS;
}
