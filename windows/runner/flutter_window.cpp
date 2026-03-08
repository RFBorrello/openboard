#include "flutter_window.h"

#include <optional>
#include <string>

#include <shobjidl.h>
#include <wrl/client.h>

#include "flutter/generated_plugin_registrant.h"

namespace {

std::string WideToUtf8(const std::wstring& value) {
  if (value.empty()) {
    return {};
  }

  const int target_size = WideCharToMultiByte(
      CP_UTF8, 0, value.c_str(), -1, nullptr, 0, nullptr, nullptr);
  if (target_size <= 1) {
    return {};
  }

  std::string converted(target_size - 1, '\0');
  WideCharToMultiByte(CP_UTF8, 0, value.c_str(), -1, converted.data(),
                      target_size, nullptr, nullptr);
  return converted;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

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
  RegisterPlatformChannels();
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  file_picker_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
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
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

void FlutterWindow::RegisterPlatformChannels() {
  file_picker_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "openboard/file_picker",
          &flutter::StandardMethodCodec::GetInstance());

  file_picker_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() != "pickCsvFile") {
          result->NotImplemented();
          return;
        }

        const auto path = ShowOpenCsvDialog();
        if (path.empty()) {
          result->Success(flutter::EncodableValue());
          return;
        }

        result->Success(flutter::EncodableValue(path));
      });
}

std::string FlutterWindow::ShowOpenCsvDialog() {
  Microsoft::WRL::ComPtr<IFileOpenDialog> dialog;
  HRESULT hr = CoCreateInstance(CLSID_FileOpenDialog, nullptr,
                                CLSCTX_INPROC_SERVER,
                                IID_PPV_ARGS(&dialog));
  if (FAILED(hr)) {
    return {};
  }

  DWORD options = 0;
  if (SUCCEEDED(dialog->GetOptions(&options))) {
    dialog->SetOptions(options | FOS_FORCEFILESYSTEM | FOS_FILEMUSTEXIST |
                       FOS_PATHMUSTEXIST);
  }

  const COMDLG_FILTERSPEC filters[] = {
      {L"CSV files", L"*.csv"},
      {L"All files", L"*.*"},
  };
  dialog->SetFileTypes(ARRAYSIZE(filters), filters);
  dialog->SetFileTypeIndex(1);
  dialog->SetDefaultExtension(L"csv");
  dialog->SetTitle(L"Open CSV");

  hr = dialog->Show(GetHandle());
  if (hr == HRESULT_FROM_WIN32(ERROR_CANCELLED) || FAILED(hr)) {
    return {};
  }

  Microsoft::WRL::ComPtr<IShellItem> item;
  hr = dialog->GetResult(&item);
  if (FAILED(hr)) {
    return {};
  }

  PWSTR raw_path = nullptr;
  hr = item->GetDisplayName(SIGDN_FILESYSPATH, &raw_path);
  if (FAILED(hr) || raw_path == nullptr) {
    return {};
  }

  const std::wstring path(raw_path);
  CoTaskMemFree(raw_path);
  return WideToUtf8(path);
}
