#include "flutter_window.h"

#include <flutter/standard_method_codec.h>
#include <ole2.h>
#include <roapi.h>
#include <shellapi.h>
#include <shobjidl.h>
#include <userconsentverifierinterop.h>
#include <wincred.h>
#include <windows.security.credentials.ui.h>
#include <winstring.h>

#include <atomic>
#include <cstdint>
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

double GetDoubleArg(const flutter::EncodableMap& args, const char* key,
                    double default_val) {
  auto it = args.find(flutter::EncodableValue(key));
  if (it != args.end()) {
    if (std::holds_alternative<double>(it->second)) {
      return std::get<double>(it->second);
    }
    if (std::holds_alternative<int32_t>(it->second)) {
      return static_cast<double>(std::get<int32_t>(it->second));
    }
    if (std::holds_alternative<int64_t>(it->second)) {
      return static_cast<double>(std::get<int64_t>(it->second));
    }
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

template <typename TResult>
class WinRtAsyncCompletionSignal final
    : public ABI::Windows::Foundation::IAsyncOperationCompletedHandler<
          TResult> {
 public:
  explicit WinRtAsyncCompletionSignal(HANDLE done_event)
      : done_event_(done_event) {}

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid,
                                           void** ppvObject) override {
    if (ppvObject == nullptr) {
      return E_POINTER;
    }
    if (riid == IID_IUnknown ||
        riid == __uuidof(ABI::Windows::Foundation::
                             IAsyncOperationCompletedHandler<TResult>)) {
      *ppvObject = static_cast<
          ABI::Windows::Foundation::IAsyncOperationCompletedHandler<TResult>*>(
          this);
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

  HRESULT STDMETHODCALLTYPE Invoke(
      ABI::Windows::Foundation::IAsyncOperation<TResult>* /*asyncInfo*/,
      ABI::Windows::Foundation::AsyncStatus /*status*/) override {
    if (done_event_ != nullptr) {
      ::SetEvent(done_event_);
    }
    return S_OK;
  }

 private:
  ~WinRtAsyncCompletionSignal() = default;
  std::atomic<ULONG> ref_count_{1};
  HANDLE done_event_;
};

template <typename TResult>
HRESULT AwaitWinRtOperation(
    ABI::Windows::Foundation::IAsyncOperation<TResult>* op,
    TResult* out_value) {
  if (op == nullptr || out_value == nullptr) {
    return E_INVALIDARG;
  }
  HANDLE done_event = ::CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (done_event == nullptr) {
    return HRESULT_FROM_WIN32(::GetLastError());
  }
  auto* handler = new WinRtAsyncCompletionSignal<TResult>(done_event);
  HRESULT hr = op->put_Completed(handler);
  handler->Release();
  if (SUCCEEDED(hr)) {
    DWORD wait_rc = ::WaitForSingleObject(done_event, 120000);
    if (wait_rc == WAIT_OBJECT_0) {
      hr = op->GetResults(out_value);
    } else {
      hr = HRESULT_FROM_WIN32(ERROR_TIMEOUT);
    }
  }
  ::CloseHandle(done_event);
  return hr;
}

struct AuthThreadTask {
  HWND owner_hwnd;
  std::wstring reason;
  std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result;
};

enum class WinAuthStatus { kAuthenticated, kCanceled, kFailed, kNeedFallback };

WinAuthStatus TryWindowsHelloConsent(HWND owner_hwnd,
                                     const std::wstring& reason,
                                     std::string* out_msg) {
  using ABI::Windows::Foundation::IAsyncOperation;
  using ABI::Windows::Security::Credentials::UI::IUserConsentVerifierStatics;
  using ABI::Windows::Security::Credentials::UI::
      UserConsentVerificationResult;
  using ABI::Windows::Security::Credentials::UI::
      UserConsentVerificationResult_Canceled;
  using ABI::Windows::Security::Credentials::UI::
      UserConsentVerificationResult_DeviceNotPresent;
  using ABI::Windows::Security::Credentials::UI::
      UserConsentVerificationResult_DisabledByPolicy;
  using ABI::Windows::Security::Credentials::UI::
      UserConsentVerificationResult_NotConfiguredForUser;
  using ABI::Windows::Security::Credentials::UI::
      UserConsentVerificationResult_RetriesExhausted;
  using ABI::Windows::Security::Credentials::UI::
      UserConsentVerificationResult_Verified;
  using ABI::Windows::Security::Credentials::UI::
      UserConsentVerifierAvailability;
  using ABI::Windows::Security::Credentials::UI::
      UserConsentVerifierAvailability_Available;
  using ABI::Windows::Security::Credentials::UI::
      UserConsentVerifierAvailability_DeviceBusy;

  HSTRING class_id = nullptr;
  const wchar_t* kClassName =
      RuntimeClass_Windows_Security_Credentials_UI_UserConsentVerifier;
  HRESULT hr = ::WindowsCreateString(
      kClassName, static_cast<UINT32>(wcslen(kClassName)), &class_id);
  if (FAILED(hr) || class_id == nullptr) {
    return WinAuthStatus::kNeedFallback;
  }

  IUserConsentVerifierStatics* statics = nullptr;
  hr = ::RoGetActivationFactory(class_id,
                                __uuidof(IUserConsentVerifierStatics),
                                reinterpret_cast<void**>(&statics));
  ::WindowsDeleteString(class_id);
  if (FAILED(hr) || statics == nullptr) {
    return WinAuthStatus::kNeedFallback;
  }

  IAsyncOperation<UserConsentVerifierAvailability>* avail_op = nullptr;
  hr = statics->CheckAvailabilityAsync(&avail_op);
  if (FAILED(hr) || avail_op == nullptr) {
    statics->Release();
    return WinAuthStatus::kNeedFallback;
  }

  UserConsentVerifierAvailability availability =
      static_cast<UserConsentVerifierAvailability>(0);
  hr = AwaitWinRtOperation(avail_op, &availability);
  avail_op->Release();
  if (FAILED(hr) ||
      (availability != UserConsentVerifierAvailability_Available &&
       availability != UserConsentVerifierAvailability_DeviceBusy)) {
    statics->Release();
    return WinAuthStatus::kNeedFallback;
  }

  HSTRING reason_hstr = nullptr;
  ::WindowsCreateString(reason.c_str(), static_cast<UINT32>(reason.size()),
                        &reason_hstr);

  IAsyncOperation<UserConsentVerificationResult>* verify_op = nullptr;
  IUserConsentVerifierInterop* interop = nullptr;
  if (owner_hwnd != nullptr &&
      SUCCEEDED(statics->QueryInterface(__uuidof(IUserConsentVerifierInterop),
                                        reinterpret_cast<void**>(&interop))) &&
      interop != nullptr) {
    hr = interop->RequestVerificationForWindowAsync(
        owner_hwnd, reason_hstr,
        __uuidof(IAsyncOperation<UserConsentVerificationResult>),
        reinterpret_cast<void**>(&verify_op));
    interop->Release();
  } else {
    hr = statics->RequestVerificationAsync(reason_hstr, &verify_op);
  }

  if (reason_hstr != nullptr) {
    ::WindowsDeleteString(reason_hstr);
  }
  statics->Release();

  if (FAILED(hr) || verify_op == nullptr) {
    return WinAuthStatus::kNeedFallback;
  }

  UserConsentVerificationResult verify_result =
      UserConsentVerificationResult_Canceled;
  hr = AwaitWinRtOperation(verify_op, &verify_result);
  verify_op->Release();
  if (FAILED(hr)) {
    return WinAuthStatus::kNeedFallback;
  }

  switch (verify_result) {
    case UserConsentVerificationResult_Verified:
      return WinAuthStatus::kAuthenticated;
    case UserConsentVerificationResult_Canceled:
      if (out_msg != nullptr) {
        *out_msg = "\xE5\xB7\xB2\xE5\x8F\x96\xE6\xB6\x88\xE8\xBA\xAB\xE4\xBB\xBD\xE9\xAA\x8C\xE8\xAF\x81";
      }
      return WinAuthStatus::kCanceled;
    case UserConsentVerificationResult_RetriesExhausted:
      if (out_msg != nullptr) {
        *out_msg = "\xE9\xAA\x8C\xE8\xAF\x81\xE5\xA4\xB1\xE8\xB4\xA5\xE6\xAC\xA1\xE6\x95\xB0\xE8\xBF\x87\xE5\xA4\x9A\xEF\xBC\x8C\xE8\xAF\xB7\xE7\xA8\x8D\xE5\x90\x8E\xE9\x87\x8D\xE8\xAF\x95";
      }
      return WinAuthStatus::kFailed;
    case UserConsentVerificationResult_DeviceNotPresent:
    case UserConsentVerificationResult_NotConfiguredForUser:
    case UserConsentVerificationResult_DisabledByPolicy:
    default:
      return WinAuthStatus::kNeedFallback;
  }
}

WinAuthStatus VerifyViaWindowsCredentialsPrompt(HWND owner_hwnd,
                                                const std::wstring& reason,
                                                std::string* out_msg) {
  wchar_t current_user[CREDUI_MAX_USERNAME_LENGTH + 1] = {};
  DWORD current_user_len = CREDUI_MAX_USERNAME_LENGTH + 1;
  std::wstring prefill_user;
  if (::GetUserNameW(current_user, &current_user_len) &&
      current_user[0] != L'\0') {
    prefill_user = std::wstring(L".\\") + current_user;
  }

  std::vector<BYTE> in_auth_buf;
  DWORD in_buf_size = 0;
  if (!prefill_user.empty()) {
    if (!::CredPackAuthenticationBufferW(
            0, const_cast<LPWSTR>(prefill_user.c_str()),
            const_cast<LPWSTR>(L""), nullptr, &in_buf_size) &&
        ::GetLastError() == ERROR_INSUFFICIENT_BUFFER && in_buf_size > 0) {
      in_auth_buf.resize(in_buf_size, 0);
      if (!::CredPackAuthenticationBufferW(
              0, const_cast<LPWSTR>(prefill_user.c_str()),
              const_cast<LPWSTR>(L""), in_auth_buf.data(), &in_buf_size)) {
        in_auth_buf.clear();
        in_buf_size = 0;
      }
    }
  }

  CREDUI_INFOW cui = {};
  cui.cbSize = sizeof(CREDUI_INFOW);
  cui.hwndParent = owner_hwnd;
  cui.pszCaptionText = L"TermX \x5B89\x5168\x8EAB\x4EFD\x9A8C\x8BC1";
  cui.pszMessageText = reason.c_str();

  DWORD auth_error = NO_ERROR;
  for (int attempt = 0; attempt < 3; ++attempt) {
    ULONG auth_package = 0;
    LPVOID out_buf = nullptr;
    ULONG out_buf_size = 0;
    BOOL save_cred = FALSE;

    DWORD rc = ::CredUIPromptForWindowsCredentialsW(
        &cui, auth_error, &auth_package,
        in_auth_buf.empty() ? nullptr : in_auth_buf.data(), in_buf_size,
        &out_buf, &out_buf_size, &save_cred, CREDUIWIN_GENERIC);

    if (rc == ERROR_CANCELLED) {
      if (out_msg != nullptr) {
        *out_msg = "\xE5\xB7\xB2\xE5\x8F\x96\xE6\xB6\x88\xE8\xBA\xAB\xE4\xBB\xBD\xE9\xAA\x8C\xE8\xAF\x81";
      }
      return WinAuthStatus::kCanceled;
    }
    if (rc != NO_ERROR || out_buf == nullptr) {
      if (out_msg != nullptr) {
        *out_msg = "\xE6\x97\xA0\xE6\xB3\x95\xE8\xB0\x83\xE8\xB5\xB7 Windows \xE5\xAE\x89\xE5\x85\xA8\xE5\x87\xAD\xE6\x8D\xAE\xE7\xAA\x97\xE5\x8F\xA3";
      }
      return WinAuthStatus::kFailed;
    }

    wchar_t unpacked_user[CREDUI_MAX_USERNAME_LENGTH + 1] = {};
    wchar_t unpacked_domain[CREDUI_MAX_DOMAIN_TARGET_LENGTH + 1] = {};
    wchar_t unpacked_pwd[CREDUI_MAX_PASSWORD_LENGTH + 1] = {};
    DWORD max_user = CREDUI_MAX_USERNAME_LENGTH + 1;
    DWORD max_domain = CREDUI_MAX_DOMAIN_TARGET_LENGTH + 1;
    DWORD max_pwd = CREDUI_MAX_PASSWORD_LENGTH + 1;

    BOOL unpacked = ::CredUnPackAuthenticationBufferW(
        CRED_PACK_PROTECTED_CREDENTIALS, out_buf, out_buf_size, unpacked_user,
        &max_user, unpacked_domain, &max_domain, unpacked_pwd, &max_pwd);
    if (!unpacked) {
      max_user = CREDUI_MAX_USERNAME_LENGTH + 1;
      max_domain = CREDUI_MAX_DOMAIN_TARGET_LENGTH + 1;
      max_pwd = CREDUI_MAX_PASSWORD_LENGTH + 1;
      unpacked = ::CredUnPackAuthenticationBufferW(
          0, out_buf, out_buf_size, unpacked_user, &max_user, unpacked_domain,
          &max_domain, unpacked_pwd, &max_pwd);
    }

    ::SecureZeroMemory(out_buf, out_buf_size);
    ::CoTaskMemFree(out_buf);

    if (!unpacked) {
      ::SecureZeroMemory(unpacked_pwd, sizeof(unpacked_pwd));
      auth_error = ERROR_LOGON_FAILURE;
      continue;
    }

    std::wstring login_user = unpacked_user;
    std::wstring login_domain = unpacked_domain;
    size_t slash_pos = login_user.find(L'\\');
    if (slash_pos != std::wstring::npos) {
      if (login_domain.empty()) {
        login_domain = login_user.substr(0, slash_pos);
      }
      login_user = login_user.substr(slash_pos + 1);
    }
    if (login_domain.empty() && login_user.find(L'@') == std::wstring::npos) {
      login_domain = L".";
    }

    const bool pwd_is_empty = (unpacked_pwd[0] == L'\0');
    HANDLE token = nullptr;
    BOOL logged_in = ::LogonUserW(
        login_user.c_str(),
        login_domain.empty() ? nullptr : login_domain.c_str(), unpacked_pwd,
        LOGON32_LOGON_INTERACTIVE, LOGON32_PROVIDER_DEFAULT, &token);
    DWORD logon_err = logged_in ? NO_ERROR : ::GetLastError();
    if (!logged_in && logon_err == ERROR_LOGON_TYPE_NOT_GRANTED) {
      logged_in = ::LogonUserW(
          login_user.c_str(),
          login_domain.empty() ? nullptr : login_domain.c_str(), unpacked_pwd,
          LOGON32_LOGON_NETWORK, LOGON32_PROVIDER_DEFAULT, &token);
      logon_err = logged_in ? NO_ERROR : ::GetLastError();
    }

    ::SecureZeroMemory(unpacked_pwd, sizeof(unpacked_pwd));

    if (logged_in) {
      if (token != nullptr) {
        ::CloseHandle(token);
      }
      return WinAuthStatus::kAuthenticated;
    }
    if (logon_err == ERROR_ACCOUNT_RESTRICTION && pwd_is_empty) {
      return WinAuthStatus::kAuthenticated;
    }
    auth_error = logon_err != NO_ERROR ? logon_err : ERROR_LOGON_FAILURE;
  }

  if (out_msg != nullptr) {
    *out_msg = "Windows \xE8\xB4\xA6\xE6\x88\xB7\xE5\xAF\x86\xE7\xA0\x81\xE9\xAA\x8C\xE8\xAF\x81\xE6\x9C\xAA\xE9\x80\x9A\xE8\xBF\x87";
  }
  return WinAuthStatus::kFailed;
}

DWORD WINAPI RunWindowsAuthThread(LPVOID param) {
  std::unique_ptr<AuthThreadTask> task(static_cast<AuthThreadTask*>(param));
  HRESULT ro_hr = ::RoInitialize(RO_INIT_MULTITHREADED);

  std::wstring prompt_reason = task->reason.empty()
                                   ? L"\x8BF7\x9A8C\x8BC1\x60A8\x7684\x7CFB\x7EDF\x8EAB\x4EFD\x4EE5\x67E5\x770B\x5DF2\x4FDD\x5B58\x7684\x767B\x5F55\x5BC6\x7801"
                                   : task->reason;
  std::string message;
  WinAuthStatus status =
      TryWindowsHelloConsent(task->owner_hwnd, prompt_reason, &message);
  if (status == WinAuthStatus::kNeedFallback) {
    status = VerifyViaWindowsCredentialsPrompt(task->owner_hwnd, prompt_reason,
                                               &message);
  }

  if (SUCCEEDED(ro_hr)) {
    ::RoUninitialize();
  }

  const char* status_str = "failed";
  if (status == WinAuthStatus::kAuthenticated) {
    status_str = "authenticated";
  } else if (status == WinAuthStatus::kCanceled) {
    status_str = "canceled";
  }

  flutter::EncodableMap payload = {
      {flutter::EncodableValue("status"),
       flutter::EncodableValue(std::string(status_str))},
      {flutter::EncodableValue("message"), flutter::EncodableValue(message)},
  };
  task->result->Success(flutter::EncodableValue(payload));
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

        if (method == "authenticateUser") {
          auto* task = new AuthThreadTask();
          task->owner_hwnd = owner_hwnd;
          task->reason = Utf16FromUtf8(GetStringArg(args, "reason"));
          task->result = std::move(result);

          HANDLE thread = ::CreateThread(nullptr, 0, RunWindowsAuthThread, task,
                                         0, nullptr);
          if (thread != nullptr) {
            ::CloseHandle(thread);
          } else {
            task->result->Error("THREAD_ERROR",
                                "Failed to start Windows authentication thread.");
            delete task;
          }
          return;
        }

        if (method == "setWindowOpacity") {
          double raw_opacity = GetDoubleArg(args, "opacity", 1.0);
          double clamped = raw_opacity < 0.35
                               ? 0.35
                               : (raw_opacity > 1.0 ? 1.0 : raw_opacity);
          if (owner_hwnd != nullptr && ::IsWindow(owner_hwnd)) {
            LONG_PTR ex_style = ::GetWindowLongPtr(owner_hwnd, GWL_EXSTYLE);
            if (clamped >= 0.999) {
              if ((ex_style & WS_EX_LAYERED) != 0) {
                ::SetLayeredWindowAttributes(owner_hwnd, 0, 255, LWA_ALPHA);
                ::SetWindowLongPtr(owner_hwnd, GWL_EXSTYLE,
                                   ex_style & ~static_cast<LONG_PTR>(WS_EX_LAYERED));
                ::RedrawWindow(
                    owner_hwnd, nullptr, nullptr,
                    RDW_ERASE | RDW_INVALIDATE | RDW_FRAME | RDW_ALLCHILDREN);
              }
            } else {
              int alpha_int = static_cast<int>(clamped * 255.0 + 0.5);
              if (alpha_int < 90) alpha_int = 90;
              if (alpha_int > 255) alpha_int = 255;
              BYTE alpha = static_cast<BYTE>(alpha_int);
              if ((ex_style & WS_EX_LAYERED) == 0) {
                ::SetWindowLongPtr(owner_hwnd, GWL_EXSTYLE,
                                   ex_style | static_cast<LONG_PTR>(WS_EX_LAYERED));
              }
              ::SetLayeredWindowAttributes(owner_hwnd, 0, alpha, LWA_ALPHA);
            }
          }
          HKEY hkey = nullptr;
          if (::RegCreateKeyExW(HKEY_CURRENT_USER,
                                L"Software\\TermX\\WindowPlacement", 0, nullptr,
                                REG_OPTION_NON_VOLATILE, KEY_WRITE, nullptr,
                                &hkey, nullptr) == ERROR_SUCCESS) {
            DWORD permille = static_cast<DWORD>(clamped * 1000.0 + 0.5);
            ::RegSetValueExW(hkey, L"OpacityPermille", 0, REG_DWORD,
                             reinterpret_cast<const BYTE*>(&permille),
                             sizeof(DWORD));
            ::RegCloseKey(hkey);
          }
          result->Success(flutter::EncodableValue(clamped));
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

void FlutterWindow::RestoreSavedWindowState() {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr || !::IsWindow(hwnd)) {
    return;
  }

  HKEY hkey = nullptr;
  if (::RegOpenKeyExW(HKEY_CURRENT_USER, L"Software\\TermX\\WindowPlacement", 0,
                      KEY_READ, &hkey) != ERROR_SUCCESS) {
    UpdateCachedNormalRect(hwnd);
    return;
  }

  auto read_dword = [&](const wchar_t* name, DWORD* out) -> bool {
    DWORD type = 0;
    DWORD data = 0;
    DWORD size = sizeof(DWORD);
    if (::RegQueryValueExW(hkey, name, nullptr, &type,
                           reinterpret_cast<LPBYTE>(&data),
                           &size) == ERROR_SUCCESS &&
        type == REG_DWORD && size == sizeof(DWORD)) {
      *out = data;
      return true;
    }
    return false;
  };

  DWORD raw_l = 0, raw_t = 0, raw_r = 0, raw_b = 0;
  if (read_dword(L"Left", &raw_l) && read_dword(L"Top", &raw_t) &&
      read_dword(L"Right", &raw_r) && read_dword(L"Bottom", &raw_b)) {
    LONG left = static_cast<LONG>(static_cast<int32_t>(raw_l));
    LONG top = static_cast<LONG>(static_cast<int32_t>(raw_t));
    LONG right = static_cast<LONG>(static_cast<int32_t>(raw_r));
    LONG bottom = static_cast<LONG>(static_cast<int32_t>(raw_b));
    LONG width = right - left;
    LONG height = bottom - top;
    if (width >= 600 && width <= 7680 && height >= 420 && height <= 4320) {
      RECT title_probe = {left + 40, top + 12,
                          (right - 40 > left + 80) ? (right - 40) : (left + 80),
                          top + 48};
      if (::MonitorFromRect(&title_probe, MONITOR_DEFAULTTONULL) != nullptr) {
        ::SetWindowPos(hwnd, nullptr, left, top, width, height,
                       SWP_NOZORDER | SWP_NOACTIVATE);
        last_normal_rect_ = {left, top, right, bottom};
        has_normal_rect_ = true;
      }
    }
  }

  DWORD maximized = 0;
  if (read_dword(L"Maximized", &maximized)) {
    start_maximized_ = (maximized != 0);
  }

  DWORD opacity_permille = 1000;
  if (read_dword(L"OpacityPermille", &opacity_permille) &&
      opacity_permille >= 350 && opacity_permille < 999) {
    int alpha_int =
        static_cast<int>((static_cast<double>(opacity_permille) / 1000.0) *
                             255.0 +
                         0.5);
    if (alpha_int < 90) alpha_int = 90;
    if (alpha_int > 255) alpha_int = 255;
    LONG_PTR ex_style = ::GetWindowLongPtr(hwnd, GWL_EXSTYLE);
    ::SetWindowLongPtr(hwnd, GWL_EXSTYLE,
                       ex_style | static_cast<LONG_PTR>(WS_EX_LAYERED));
    ::SetLayeredWindowAttributes(hwnd, 0, static_cast<BYTE>(alpha_int),
                                 LWA_ALPHA);
  }

  ::RegCloseKey(hkey);
  if (!has_normal_rect_) {
    UpdateCachedNormalRect(hwnd);
  }
}

void FlutterWindow::UpdateCachedNormalRect(HWND hwnd) noexcept {
  if (hwnd == nullptr || !::IsWindow(hwnd) || ::IsZoomed(hwnd) ||
      ::IsIconic(hwnd)) {
    return;
  }
  RECT rc{};
  if (::GetWindowRect(hwnd, &rc)) {
    if ((rc.right - rc.left) >= 480 && (rc.bottom - rc.top) >= 340) {
      last_normal_rect_ = rc;
      has_normal_rect_ = true;
    }
  }
}

void FlutterWindow::PersistWindowState(HWND hwnd) noexcept {
  if (hwnd == nullptr || !::IsWindow(hwnd)) {
    return;
  }
  UpdateCachedNormalRect(hwnd);

  bool maximized = (::IsZoomed(hwnd) != FALSE);
  if (::IsIconic(hwnd)) {
    WINDOWPLACEMENT wp{};
    wp.length = sizeof(WINDOWPLACEMENT);
    if (::GetWindowPlacement(hwnd, &wp)) {
      maximized = (wp.flags & WPF_RESTORETOMAXIMIZED) != 0;
    }
  }

  HKEY hkey = nullptr;
  if (::RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\TermX\\WindowPlacement",
                        0, nullptr, REG_OPTION_NON_VOLATILE, KEY_WRITE, nullptr,
                        &hkey, nullptr) != ERROR_SUCCESS) {
    return;
  }

  if (has_normal_rect_) {
    DWORD l = static_cast<DWORD>(static_cast<int32_t>(last_normal_rect_.left));
    DWORD t = static_cast<DWORD>(static_cast<int32_t>(last_normal_rect_.top));
    DWORD r = static_cast<DWORD>(static_cast<int32_t>(last_normal_rect_.right));
    DWORD b =
        static_cast<DWORD>(static_cast<int32_t>(last_normal_rect_.bottom));
    ::RegSetValueExW(hkey, L"Left", 0, REG_DWORD,
                     reinterpret_cast<const BYTE*>(&l), sizeof(DWORD));
    ::RegSetValueExW(hkey, L"Top", 0, REG_DWORD,
                     reinterpret_cast<const BYTE*>(&t), sizeof(DWORD));
    ::RegSetValueExW(hkey, L"Right", 0, REG_DWORD,
                     reinterpret_cast<const BYTE*>(&r), sizeof(DWORD));
    ::RegSetValueExW(hkey, L"Bottom", 0, REG_DWORD,
                     reinterpret_cast<const BYTE*>(&b), sizeof(DWORD));
  }
  DWORD max_val = maximized ? 1u : 0u;
  ::RegSetValueExW(hkey, L"Maximized", 0, REG_DWORD,
                   reinterpret_cast<const BYTE*>(&max_val), sizeof(DWORD));
  ::RegCloseKey(hkey);
}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RestoreSavedWindowState();

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

  auto show_restored = [this]() {
    HWND hwnd = GetHandle();
    if (start_maximized_ && hwnd != nullptr && ::IsWindow(hwnd)) {
      ::ShowWindow(hwnd, SW_SHOWMAXIMIZED);
    } else {
      this->Show();
    }
  };

  flutter_controller_->engine()->SetNextFrameCallback(show_restored);

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  // Explicitly show window on create in case NextFrameCallback is delayed or
  // missed
  show_restored();

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
  switch (message) {
    case WM_MOVE:
      UpdateCachedNormalRect(hwnd);
      break;
    case WM_SIZE:
      UpdateCachedNormalRect(hwnd);
      if (wparam == SIZE_MAXIMIZED || wparam == SIZE_RESTORED) {
        PersistWindowState(hwnd);
      }
      break;
    case WM_EXITSIZEMOVE:
    case WM_CLOSE:
      PersistWindowState(hwnd);
      break;
    default:
      break;
  }

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
