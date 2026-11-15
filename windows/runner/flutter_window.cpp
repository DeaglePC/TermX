#include "flutter_window.h"

#include <flutter/standard_method_codec.h>
#include <ole2.h>
#include <shellapi.h>
#include <shobjidl.h>

#include <atomic>
#include <optional>
#include <string>
#include <vector>

#include "flutter/generated_plugin_registrant.h"
#include "utils.h"

namespace {

std::wstring Utf16FromUtf8(const std::string& utf8) {
  if (utf8.empty()) {
    return std::wstring();
  }
  int target_length = ::MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, utf8.data(),
      static_cast<int>(utf8.length()), nullptr, 0);
  if (target_length <= 0) {
    return std::wstring();
  }
  std::wstring utf16(static_cast<size_t>(target_length), L'\0');
  int converted = ::MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, utf8.data(),
      static_cast<int>(utf8.length()), utf16.data(), target_length);
  if (converted == 0) {
    return std::wstring();
  }
  return utf16;
}

std::string GetStringArg(const flutter::EncodableMap& args,
                         const char* key) {
  auto it = args.find(flutter::EncodableValue(key));
  if (it != args.end() && std::holds_alternative<std::string>(it->second)) {
    return std::get<std::string>(it->second);
  }
  return std::string();
}

bool GetBoolArg(const flutter::EncodableMap& args, const char* key,
                bool default_val) {
  auto it = args.find(flutter::EncodableValue(key));
  if (it != args.end() && std::holds_alternative<bool>(it->second)) {
    return std::get<bool>(it->second);
  }
  return default_val;
}

void ApplyInitialFolder(IFileDialog* dialog, const std::wstring& dir_path) {
  if (dir_path.empty() || dialog == nullptr) {
    return;
  }
  IShellItem* folder_item = nullptr;
  HRESULT hr = ::SHCreateItemFromParsingName(dir_path.c_str(), nullptr,
                                             IID_PPV_ARGS(&folder_item));
  if (SUCCEEDED(hr) && folder_item != nullptr) {
    dialog->SetFolder(folder_item);
    folder_item->Release();
  }
}

enum class DialogKind { kSaveFile, kPickFiles, kPickDirectory };

struct DialogThreadTask {
  DialogKind kind;
  HWND owner_hwnd;
  std::wstring suggested_name;
  std::wstring initial_dir;
  bool allow_multiple;
  std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result;
};

DWORD WINAPI RunFileDialogThread(LPVOID param) {
  std::unique_ptr<DialogThreadTask> task(
      static_cast<DialogThreadTask*>(param));
  HRESULT co_hr = ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  if (task->kind == DialogKind::kSaveFile) {
    IFileSaveDialog* save_dlg = nullptr;
    HRESULT hr = ::CoCreateInstance(CLSID_FileSaveDialog, nullptr,
                                    CLSCTX_INPROC_SERVER,
                                    IID_PPV_ARGS(&save_dlg));
    if (SUCCEEDED(hr) && save_dlg != nullptr) {
      DWORD options = 0;
      if (SUCCEEDED(save_dlg->GetOptions(&options))) {
        save_dlg->SetOptions(options | FOS_OVERWRITEPROMPT |
                             FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST);
      }
      save_dlg->SetTitle(L"\x9009\x62E9 SFTP \x4E0B\x8F7D\x4FDD\x5B58\x4F4D\x7F6E");
      if (!task->suggested_name.empty()) {
        save_dlg->SetFileName(task->suggested_name.c_str());
      }
      ApplyInitialFolder(save_dlg, task->initial_dir);

      const COMDLG_FILTERSPEC filter_spec[] = {
          {L"\x6240\x6709\x6587\x4EF6 (*.*)", L"*.*"},
      };
      save_dlg->SetFileTypes(1, filter_spec);

      if (SUCCEEDED(save_dlg->Show(task->owner_hwnd))) {
        IShellItem* item = nullptr;
        if (SUCCEEDED(save_dlg->GetResult(&item)) && item != nullptr) {
          PWSTR file_path = nullptr;
          if (SUCCEEDED(
                  item->GetDisplayName(SIGDN_FILESYSPATH, &file_path)) &&
              file_path != nullptr) {
            std::string utf8_path = Utf8FromUtf16(file_path);
            ::CoTaskMemFree(file_path);
            item->Release();
            save_dlg->Release();
            if (SUCCEEDED(co_hr)) {
              ::CoUninitialize();
            }
            task->result->Success(flutter::EncodableValue(utf8_path));
            return 0;
          }
          item->Release();
        }
      }
      save_dlg->Release();
    }
    if (SUCCEEDED(co_hr)) {
      ::CoUninitialize();
    }
    task->result->Success(flutter::EncodableValue());
    return 0;
  }

  if (task->kind == DialogKind::kPickFiles) {
    IFileOpenDialog* open_dlg = nullptr;
    HRESULT hr = ::CoCreateInstance(CLSID_FileOpenDialog, nullptr,
                                    CLSCTX_INPROC_SERVER,
                                    IID_PPV_ARGS(&open_dlg));
    flutter::EncodableList picked_list;
    if (SUCCEEDED(hr) && open_dlg != nullptr) {
      DWORD options = 0;
      if (SUCCEEDED(open_dlg->GetOptions(&options))) {
        DWORD extra = FOS_FORCEFILESYSTEM | FOS_FILEMUSTEXIST;
        if (task->allow_multiple) {
          extra |= FOS_ALLOWMULTISELECT;
        }
        open_dlg->SetOptions(options | extra);
      }
      open_dlg->SetTitle(L"\x9009\x62E9\x8981\x901A\x8FC7 SFTP \x4E0A\x4F20\x7684\x6587\x4EF6");
      ApplyInitialFolder(open_dlg, task->initial_dir);

      if (SUCCEEDED(open_dlg->Show(task->owner_hwnd))) {
        IShellItemArray* items = nullptr;
        if (SUCCEEDED(open_dlg->GetResults(&items)) && items != nullptr) {
          DWORD count = 0;
          if (SUCCEEDED(items->GetCount(&count))) {
            for (DWORD i = 0; i < count; ++i) {
              IShellItem* item = nullptr;
              if (SUCCEEDED(items->GetItemAt(i, &item)) && item != nullptr) {
                PWSTR file_path = nullptr;
                if (SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH,
                                                   &file_path)) &&
                    file_path != nullptr) {
                  std::string utf8_path = Utf8FromUtf16(file_path);
                  if (!utf8_path.empty()) {
                    picked_list.push_back(
                        flutter::EncodableValue(utf8_path));
                  }
                  ::CoTaskMemFree(file_path);
                }
                item->Release();
              }
            }
          }
          items->Release();
        }
      }
      open_dlg->Release();
    }
    if (SUCCEEDED(co_hr)) {
      ::CoUninitialize();
    }
    task->result->Success(flutter::EncodableValue(picked_list));
    return 0;
  }

  // DialogKind::kPickDirectory
  IFileOpenDialog* dir_dlg = nullptr;
  HRESULT hr = ::CoCreateInstance(CLSID_FileOpenDialog, nullptr,
                                  CLSCTX_INPROC_SERVER,
                                  IID_PPV_ARGS(&dir_dlg));
  if (SUCCEEDED(hr) && dir_dlg != nullptr) {
    DWORD options = 0;
    if (SUCCEEDED(dir_dlg->GetOptions(&options))) {
      dir_dlg->SetOptions(options | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM |
                          FOS_PATHMUSTEXIST);
    }
    dir_dlg->SetTitle(L"\x9009\x62E9 SFTP \x4E0B\x8F7D\x4FDD\x5B58\x6587\x4EF6\x5939");
    ApplyInitialFolder(dir_dlg, task->initial_dir);

    if (SUCCEEDED(dir_dlg->Show(task->owner_hwnd))) {
      IShellItem* item = nullptr;
      if (SUCCEEDED(dir_dlg->GetResult(&item)) && item != nullptr) {
        PWSTR folder_path = nullptr;
        if (SUCCEEDED(
                item->GetDisplayName(SIGDN_FILESYSPATH, &folder_path)) &&
            folder_path != nullptr) {
          std::string utf8_path = Utf8FromUtf16(folder_path);
          ::CoTaskMemFree(folder_path);
          item->Release();
          dir_dlg->Release();
          if (SUCCEEDED(co_hr)) {
            ::CoUninitialize();
          }
          task->result->Success(flutter::EncodableValue(utf8_path));
          return 0;
        }
        item->Release();
      }
    }
    dir_dlg->Release();
  }

  if (SUCCEEDED(co_hr)) {
    ::CoUninitialize();
  }
  task->result->Success(flutter::EncodableValue());
  return 0;
}

}  // namespace

class Win32FileDropTarget : public IDropTarget {
 public:
  Win32FileDropTarget(
      HWND view_hwnd,
      flutter::MethodChannel<flutter::EncodableValue>* channel)
      : view_hwnd_(view_hwnd), channel_(channel) {}

  virtual ~Win32FileDropTarget() = default;

  void Detach() { channel_ = nullptr; }

  // IUnknown
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid,
                                           void** ppvObject) override {
    if (ppvObject == nullptr) {
      return E_POINTER;
    }
    if (riid == IID_IUnknown || riid == IID_IDropTarget) {
      *ppvObject = static_cast<IDropTarget*>(this);
      AddRef();
      return S_OK;
    }
    *ppvObject = nullptr;
    return E_NOINTERFACE;
  }

  ULONG STDMETHODCALLTYPE AddRef() override { return ++ref_count_; }

  ULONG STDMETHODCALLTYPE Release() override {
    ULONG count = --ref_count_;
    if (count == 0) {
      delete this;
    }
    return count;
  }

  // IDropTarget
  HRESULT STDMETHODCALLTYPE DragEnter(IDataObject* pDataObj,
                                      DWORD /*grfKeyState*/, POINTL pt,
                                      DWORD* pdwEffect) override {
    has_files_ = HasHdropData(pDataObj);
    if (pdwEffect != nullptr) {
      *pdwEffect = has_files_ ? DROPEFFECT_COPY : DROPEFFECT_NONE;
    }
    if (has_files_ && channel_ != nullptr) {
      double lx = 0.0;
      double ly = 0.0;
      ScreenToLogical(pt, &lx, &ly);
      flutter::EncodableMap payload = {
          {flutter::EncodableValue("x"), flutter::EncodableValue(lx)},
          {flutter::EncodableValue("y"), flutter::EncodableValue(ly)},
      };
      channel_->InvokeMethod(
          "onDragEntered",
          std::make_unique<flutter::EncodableValue>(payload));
    }
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE DragOver(DWORD /*grfKeyState*/, POINTL pt,
                                     DWORD* pdwEffect) override {
    if (pdwEffect != nullptr) {
      *pdwEffect = has_files_ ? DROPEFFECT_COPY : DROPEFFECT_NONE;
    }
    if (has_files_ && channel_ != nullptr) {
      double lx = 0.0;
      double ly = 0.0;
      ScreenToLogical(pt, &lx, &ly);
      flutter::EncodableMap payload = {
          {flutter::EncodableValue("x"), flutter::EncodableValue(lx)},
          {flutter::EncodableValue("y"), flutter::EncodableValue(ly)},
      };
      channel_->InvokeMethod(
          "onDragUpdated",
          std::make_unique<flutter::EncodableValue>(payload));
    }
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE DragLeave() override {
    if (has_files_ && channel_ != nullptr) {
      channel_->InvokeMethod(
          "onDragExited", std::make_unique<flutter::EncodableValue>());
    }
    has_files_ = false;
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE Drop(IDataObject* pDataObj, DWORD /*grfKeyState*/,
                                 POINTL pt, DWORD* pdwEffect) override {
    if (pdwEffect != nullptr) {
      *pdwEffect = has_files_ ? DROPEFFECT_COPY : DROPEFFECT_NONE;
    }
    if (has_files_ && pDataObj != nullptr && channel_ != nullptr) {
      FORMATETC fmt = {CF_HDROP, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
      STGMEDIUM stg = {};
      if (SUCCEEDED(pDataObj->GetData(&fmt, &stg))) {
        HDROP hdrop = static_cast<HDROP>(::GlobalLock(stg.hGlobal));
        if (hdrop != nullptr) {
          flutter::EncodableList paths;
          UINT file_count = ::DragQueryFileW(hdrop, 0xFFFFFFFF, nullptr, 0);
          for (UINT i = 0; i < file_count; ++i) {
            UINT len = ::DragQueryFileW(hdrop, i, nullptr, 0);
            if (len > 0) {
              std::vector<wchar_t> buf(static_cast<size_t>(len) + 1, L'\0');
              if (::DragQueryFileW(hdrop, i, buf.data(), len + 1) > 0) {
                std::string utf8 = Utf8FromUtf16(buf.data());
                if (!utf8.empty()) {
                  paths.push_back(flutter::EncodableValue(utf8));
                }
              }
            }
          }
          ::GlobalUnlock(stg.hGlobal);

          if (!paths.empty()) {
            double lx = 0.0;
            double ly = 0.0;
            ScreenToLogical(pt, &lx, &ly);
            flutter::EncodableMap payload = {
                {flutter::EncodableValue("x"), flutter::EncodableValue(lx)},
                {flutter::EncodableValue("y"), flutter::EncodableValue(ly)},
                {flutter::EncodableValue("paths"),
                 flutter::EncodableValue(paths)},
            };
            channel_->InvokeMethod(
                "onFilesDropped",
                std::make_unique<flutter::EncodableValue>(payload));
          }
        }
        ::ReleaseStgMedium(&stg);
      }
    }
    has_files_ = false;
    return S_OK;
  }

 private:
  static bool HasHdropData(IDataObject* data_obj) {
    if (data_obj == nullptr) {
      return false;
    }
    FORMATETC fmt = {CF_HDROP, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
    return data_obj->QueryGetData(&fmt) == S_OK;
  }

  void ScreenToLogical(POINTL pt, double* out_x, double* out_y) const {
    POINT client_pt = {pt.x, pt.y};
    ::ScreenToClient(view_hwnd_, &client_pt);
    UINT dpi = FlutterDesktopGetDpiForHWND(view_hwnd_);
    double scale = dpi > 0 ? (static_cast<double>(dpi) / 96.0) : 1.0;
    *out_x = static_cast<double>(client_pt.x) / scale;
    *out_y = static_cast<double>(client_pt.y) / scale;
  }

  std::atomic<ULONG> ref_count_{1};
  HWND view_hwnd_;
  flutter::MethodChannel<flutter::EncodableValue>* channel_;
  bool has_files_ = false;
};

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

void FlutterWindow::SetupNativeIoChannel() {
  native_io_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "com.termx.desktop/native_io",
          &flutter::StandardMethodCodec::GetInstance());

  HWND owner_hwnd = GetHandle();
  native_io_channel_->SetMethodCallHandler(
      [owner_hwnd](
          const flutter::MethodCall<flutter::EncodableValue>& call,
          std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
              result) {
        flutter::EncodableMap args;
        if (call.arguments() != nullptr &&
            std::holds_alternative<flutter::EncodableMap>(*call.arguments())) {
          args = std::get<flutter::EncodableMap>(*call.arguments());
        }

        const std::string& method = call.method_name();
        if (method == "saveFile" || method == "pickFiles" ||
            method == "pickDirectory") {
          auto* task = new DialogThreadTask();
          task->owner_hwnd = owner_hwnd;
          task->suggested_name =
              Utf16FromUtf8(GetStringArg(args, "suggestedName"));
          task->initial_dir =
              Utf16FromUtf8(GetStringArg(args, "initialDirectory"));
          task->allow_multiple = GetBoolArg(args, "allowMultiple", true);
          task->kind = method == "saveFile"
                           ? DialogKind::kSaveFile
                           : (method == "pickFiles"
                                  ? DialogKind::kPickFiles
                                  : DialogKind::kPickDirectory);
          task->result = std::move(result);

          HANDLE thread =
              ::CreateThread(nullptr, 0, RunFileDialogThread, task, 0, nullptr);
          if (thread != nullptr) {
            ::CloseHandle(thread);
          } else {
            task->result->Error("THREAD_ERROR",
                                "Failed to start native file dialog thread.");
            delete task;
          }
          return;
        }

        result->NotImplemented();
      });

  HWND view_hwnd = flutter_controller_->view()->GetNativeWindow();
  drop_target_ = new Win32FileDropTarget(view_hwnd, native_io_channel_.get());
  drop_target_hwnd_ = view_hwnd;
  HRESULT hr = ::RegisterDragDrop(view_hwnd, drop_target_);
  if (hr == DRAGDROP_E_ALREADYREGISTERED) {
    ::RevokeDragDrop(view_hwnd);
    hr = ::RegisterDragDrop(view_hwnd, drop_target_);
  }
  if (FAILED(hr)) {
    drop_target_hwnd_ = owner_hwnd;
    hr = ::RegisterDragDrop(owner_hwnd, drop_target_);
    if (FAILED(hr)) {
      ::DragAcceptFiles(owner_hwnd, TRUE);
    }
  }
}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  SetupNativeIoChannel();

  flutter_controller_->engine()->SetNextFrameCallback([&]() { this->Show(); });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  // Explicitly show window on create in case NextFrameCallback is delayed or
  // missed
  this->Show();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (drop_target_ != nullptr) {
    drop_target_->Detach();
    if (drop_target_hwnd_ != nullptr) {
      ::RevokeDragDrop(drop_target_hwnd_);
      drop_target_hwnd_ = nullptr;
    }
    drop_target_->Release();
    drop_target_ = nullptr;
  }
  native_io_channel_.reset();

  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    case WM_DROPFILES: {
      HDROP hdrop = reinterpret_cast<HDROP>(wparam);
      if (hdrop != nullptr && native_io_channel_ != nullptr) {
        POINT pt = {};
        ::DragQueryPoint(hdrop, &pt);
        UINT dpi = FlutterDesktopGetDpiForHWND(hwnd);
        double scale = dpi > 0 ? (static_cast<double>(dpi) / 96.0) : 1.0;
        flutter::EncodableList paths;
        UINT count = ::DragQueryFileW(hdrop, 0xFFFFFFFF, nullptr, 0);
        for (UINT i = 0; i < count; ++i) {
          UINT len = ::DragQueryFileW(hdrop, i, nullptr, 0);
          if (len > 0) {
            std::vector<wchar_t> buf(static_cast<size_t>(len) + 1, L'\0');
            if (::DragQueryFileW(hdrop, i, buf.data(), len + 1) > 0) {
              std::string utf8 = Utf8FromUtf16(buf.data());
              if (!utf8.empty()) {
                paths.push_back(flutter::EncodableValue(utf8));
              }
            }
          }
        }
        if (!paths.empty()) {
          flutter::EncodableMap payload = {
              {flutter::EncodableValue("x"),
               flutter::EncodableValue(static_cast<double>(pt.x) / scale)},
              {flutter::EncodableValue("y"),
               flutter::EncodableValue(static_cast<double>(pt.y) / scale)},
              {flutter::EncodableValue("paths"),
               flutter::EncodableValue(paths)},
          };
          native_io_channel_->InvokeMethod(
              "onFilesDropped",
              std::make_unique<flutter::EncodableValue>(payload));
        }
      }
      if (hdrop != nullptr) {
        ::DragFinish(hdrop);
      }
      return 0;
    }
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
