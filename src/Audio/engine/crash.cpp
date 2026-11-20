// Let it crash, visibly: fatal signals and std::terminate write a report with a
// symbolized stack trace (cpptrace) and the last control commands to stderr and
// to the crash file Erlang named. Erlang reads the file when the port exits and
// posts it to Session chat. Symbolizing inside a signal handler is not
// async-signal-safe; this is best effort in a process that is ending anyway.
#include <cpptrace/cpptrace.hpp>
#include <cpptrace/formatting.hpp>
#include <fcntl.h>
#include <unistd.h>

#include <array>
#include <atomic>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <mutex>
#include <string>
#include <typeinfo>

#include "engine.h"

namespace ba {
namespace {
const char *crash_path = nullptr;
std::mutex recent_mutex;
std::array<std::string, 8> recent;
unsigned recent_count = 0;
std::atomic<bool> reporting{false};

void write_all(int fd, const std::string &text) {
    const char *p = text.data();
    size_t left = text.size();
    while (left) {
        const ssize_t n = write(fd, p, left);
        if (n <= 0) return;
        p += n, left -= size_t(n);
    }
}

void report(const std::string &reason) {
    if (reporting.exchange(true)) return;
    std::string text = "ba_audio_engine crashed: " + reason + "\n\nStack trace:\n";
    try {
        // Pruned symbols keep chat-sized lines; the crash handler's own frames
        // and C++ exception machinery are noise.
        static const auto style = cpptrace::formatter{}
                                       .symbols(cpptrace::formatter::symbol_mode::pruned)
                                       .paths(cpptrace::formatter::path_mode::basename)
                                       .hide_exception_machinery()
                                       .header("");
        text += style.format(cpptrace::generate_trace(2));
    } catch (...) {
        text += "(stack trace unavailable)\n";
    }
    text += "\nLast commands (oldest first):\n";
    if (recent_mutex.try_lock()) {
        const unsigned n = std::min<unsigned>(recent_count, recent.size());
        for (unsigned i = recent_count - n; i < recent_count; ++i) text += "  " + recent[i % recent.size()] + "\n";
        recent_mutex.unlock();
    } else {
        text += "  (unavailable: crashed while recording a command)\n";
    }
    write_all(2, text);
    if (crash_path) {
        const int fd = open(crash_path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
        if (fd >= 0) write_all(fd, text), close(fd);
    }
}

void on_signal(int sig, siginfo_t *info, void *) {
    char reason[160];
    snprintf(reason, sizeof(reason), "signal %d (%s) at address %p", sig, strsignal(sig), info ? info->si_addr : nullptr);
    report(reason);
    signal(sig, SIG_DFL);
    raise(sig);
}

void on_terminate() {
    std::string reason = "std::terminate without an active exception";
    if (const auto current = std::current_exception()) {
        try {
            std::rethrow_exception(current);
        } catch (const std::exception &e) {
            reason = "uncaught " + cpptrace::demangle(typeid(e).name()) + ": " + e.what();
        } catch (...) {
            reason = "uncaught non-standard exception";
        }
    }
    report(reason);
    signal(SIGABRT, SIG_DFL);
    std::abort();
}
}  // namespace

void install_crash_handlers(const char *file) {
    crash_path = file;
    static char alternate[1 << 16];
    stack_t stack{};
    stack.ss_sp = alternate, stack.ss_size = sizeof(alternate);
    sigaltstack(&stack, nullptr);
    struct sigaction action{};
    action.sa_sigaction = on_signal;
    action.sa_flags = SA_SIGINFO | SA_ONSTACK | SA_RESETHAND;
    sigemptyset(&action.sa_mask);
    for (int sig : {SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT, SIGTRAP}) sigaction(sig, &action, nullptr);
    signal(SIGPIPE, SIG_IGN);
    std::set_terminate(on_terminate);
}

void remember_command(const std::string &text) {
    std::lock_guard<std::mutex> lock(recent_mutex);
    recent[recent_count++ % recent.size()] = text.substr(0, 400);
}
}  // namespace ba
