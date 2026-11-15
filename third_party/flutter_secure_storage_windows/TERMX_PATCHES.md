# TermX Windows secure storage

Runtime Dart sources from flutter_secure_storage_windows 4.2.2.
Upstream: https://github.com/mogol/flutter_secure_storage
The original BSD license is retained in LICENSE.

Only the Dart plugin is registered. The legacy C++ Credential Manager plugin
is not bundled, so Visual Studio ATL is not required. The Dart DPAPI backend
is unchanged. TermX sets WindowsOptions(useBackwardCompatibility: false) and
never uses the removed legacy method channel. Do not enable that option
without restoring the upstream C++ plugin.
