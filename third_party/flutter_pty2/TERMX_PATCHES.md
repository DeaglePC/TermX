# TermX native PTY dependency

Vendored from flutter_pty2 3.0.0 (https://pub.dev/packages/flutter_pty2).
Upstream license is retained in LICENSE. Only runtime sources and build hooks
are included.

Windows spawn sets STARTF_USESTDHANDLES with null standard handles so shells
attach their input/output to ConPTY when Flutter is launched with redirected
stdio. Without this flag PowerShell renders to the parent process instead of
the terminal pane. See https://github.com/microsoft/terminal/discussions/15814.
