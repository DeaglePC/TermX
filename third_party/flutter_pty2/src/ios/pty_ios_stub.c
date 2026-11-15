#include "../common/pty_error.h"
#include "../flutter_pty.h"

/*
 * iOS / iPadOS sandboxed apps prohibit fork() / openpty() and <libproc.h> is
 * macOS-only. TermX only spawns local PTY sessions on desktop (Windows, macOS,
 * Linux); on iOS it connects over SSH2. This stub satisfies all @Native FFI
 * symbols at AOT link time on iOS while returning PTY_ERROR_UNSUPPORTED if
 * ever called.
 */

FFI_PLUGIN_EXPORT int32_t pty_session_start(
    const PtySpawnOptions *options,
    PtySession **out_session,
    PtyError *out_error)
{
    (void)options;
    if (out_session != NULL) *out_session = NULL;
    pty_error_set(
        out_error,
        PTY_ERROR_DOMAIN_INTERNAL,
        PTY_ERROR_UNSUPPORTED,
        0,
        "Local PTY is not supported on iOS");
    return -1;
}

FFI_PLUGIN_EXPORT int64_t pty_session_pid(PtySession *session)
{
    (void)session;
    return -1;
}

FFI_PLUGIN_EXPORT int32_t pty_session_try_write(
    PtySession *session,
    uint64_t request_id,
    const uint8_t *bytes,
    uint64_t length,
    PtyError *out_error)
{
    (void)session;
    (void)request_id;
    (void)bytes;
    (void)length;
    pty_error_set(
        out_error,
        PTY_ERROR_DOMAIN_INTERNAL,
        PTY_ERROR_UNSUPPORTED,
        0,
        "Local PTY is not supported on iOS");
    return PTY_WRITE_ERROR;
}

FFI_PLUGIN_EXPORT void pty_session_ack_output(
    PtySession *session,
    uint64_t byte_count)
{
    (void)session;
    (void)byte_count;
}

FFI_PLUGIN_EXPORT int32_t pty_session_resize(
    PtySession *session,
    PtySize size,
    PtyError *out_error)
{
    (void)session;
    (void)size;
    pty_error_set(
        out_error,
        PTY_ERROR_DOMAIN_INTERNAL,
        PTY_ERROR_UNSUPPORTED,
        0,
        "Local PTY is not supported on iOS");
    return -1;
}

FFI_PLUGIN_EXPORT int32_t pty_session_kill(
    PtySession *session,
    PtyError *out_error)
{
    (void)session;
    pty_error_set(
        out_error,
        PTY_ERROR_DOMAIN_INTERNAL,
        PTY_ERROR_UNSUPPORTED,
        0,
        "Local PTY is not supported on iOS");
    return -1;
}

FFI_PLUGIN_EXPORT int32_t pty_session_send_signal(
    PtySession *session,
    int32_t signal_number,
    int32_t target,
    PtyError *out_error)
{
    (void)session;
    (void)signal_number;
    (void)target;
    pty_error_set(
        out_error,
        PTY_ERROR_DOMAIN_INTERNAL,
        PTY_ERROR_UNSUPPORTED,
        0,
        "Local PTY is not supported on iOS");
    return -1;
}

FFI_PLUGIN_EXPORT void pty_session_discard_output(PtySession *session)
{
    (void)session;
}

FFI_PLUGIN_EXPORT void pty_session_begin_close(PtySession *session)
{
    (void)session;
}

FFI_PLUGIN_EXPORT void pty_session_abandon(void *session)
{
    (void)session;
}
