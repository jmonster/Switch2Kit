#pragma once
#include <cerrno>
#include <algorithm>
#include <cstdint>
#include <utility>
#include <fcntl.h>
#include <string>
#include <sys/stat.h>
#include <unistd.h>

namespace Switch2Kit {
enum class HostFileResult { OK, Missing, Invalid };
/** Explicit host settings/calibration reads only. No default path, persistence,
 * watcher or Bluetooth work. Reject special files via the opened descriptor,
 * bound paths/bytes/retries, and leave the caller's output unchanged on failure. */
inline HostFileResult readHostFile(const std::string& path, size_t limit, std::string& output) {
    if (path.empty() || path.size() > 4096 || path.find('\0') != std::string::npos ||
        !limit || limit > 524288) return HostFileResult::Invalid;
    if (std::any_of(path.begin(), path.end(), [](unsigned char c) { return c < 32 || c == 127; }))
        return HostFileResult::Invalid; // Host INI/XML selections must round-trip without injected records.
    const int fd = ::open(path.c_str(), O_RDONLY | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) return errno == ENOENT ? HostFileResult::Missing : HostFileResult::Invalid;
    struct Close { int fd; ~Close() { ::close(fd); } } close{fd};
    struct stat info{};
    if (::fstat(fd, &info) != 0 || !S_ISREG(info.st_mode) || info.st_size < 0 ||
        static_cast<uint64_t>(info.st_size) > limit) return HostFileResult::Invalid;
    std::string bytes(static_cast<size_t>(info.st_size) + 1, '\0');
    size_t count = 0;
    for (unsigned attempts = 0; attempts < 32; ++attempts) {
        const auto n = ::read(fd, bytes.data() + count, bytes.size() - count);
        if (n < 0) { if (errno == EINTR) continue; return HostFileResult::Invalid; }
        if (!n) {
            if (count != static_cast<size_t>(info.st_size)) return HostFileResult::Invalid;
            bytes.resize(count); output = std::move(bytes); return HostFileResult::OK;
        }
        count += static_cast<size_t>(n);
        if (count == bytes.size()) return HostFileResult::Invalid;
    }
    return HostFileResult::Invalid;
}
}
