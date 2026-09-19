#pragma once
#include <cerrno>
#include <algorithm>
#include <cstdint>
#include <utility>
#include <string>
#if defined(_WIN32)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#else
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#endif

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
#if defined(_WIN32)
    // Host settings store UTF-8 paths, not paths in the active Windows code page.
    const int length = ::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
        path.data(), static_cast<int>(path.size()), nullptr, 0);
    if (!length) return HostFileResult::Invalid;
    std::wstring nativePath(static_cast<size_t>(length), L'\0');
    if (::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path.data(),
        static_cast<int>(path.size()), nativePath.data(), length) != length)
        return HostFileResult::Invalid;
    // A null SECURITY_ATTRIBUTES keeps the handle non-inheritable. Check the
    // opened handle rather than the path, so replacement cannot bypass checks.
    const HANDLE file = ::CreateFileW(nativePath.c_str(), GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
        OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) {
        const DWORD error = ::GetLastError();
        return error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND
            ? HostFileResult::Missing : HostFileResult::Invalid;
    }
    struct Close { HANDLE file; ~Close() { ::CloseHandle(file); } } close{file};
    BY_HANDLE_FILE_INFORMATION info{};
    if (::GetFileType(file) != FILE_TYPE_DISK ||
        !::GetFileInformationByHandle(file, &info) ||
        (info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)) return HostFileResult::Invalid;
    const uint64_t fileSize = (static_cast<uint64_t>(info.nFileSizeHigh) << 32) | info.nFileSizeLow;
#else
    const int fd = ::open(path.c_str(), O_RDONLY | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) return errno == ENOENT ? HostFileResult::Missing : HostFileResult::Invalid;
    struct Close { int fd; ~Close() { ::close(fd); } } close{fd};
    struct stat info{};
    if (::fstat(fd, &info) != 0 || !S_ISREG(info.st_mode) || info.st_size < 0)
        return HostFileResult::Invalid;
    const uint64_t fileSize = static_cast<uint64_t>(info.st_size);
#endif
    if (fileSize > limit) return HostFileResult::Invalid;
    std::string bytes(static_cast<size_t>(fileSize) + 1, '\0');
    size_t count = 0;
    for (unsigned attempts = 0; attempts < 32; ++attempts) {
#if defined(_WIN32)
        DWORD n = 0;
        if (!::ReadFile(file, bytes.data() + count,
            static_cast<DWORD>(bytes.size() - count), &n, nullptr)) return HostFileResult::Invalid;
#else
        const auto n = ::read(fd, bytes.data() + count, bytes.size() - count);
        if (n < 0) { if (errno == EINTR) continue; return HostFileResult::Invalid; }
#endif
        if (!n) {
            if (count != static_cast<size_t>(fileSize)) return HostFileResult::Invalid;
            bytes.resize(count); output = std::move(bytes); return HostFileResult::OK;
        }
        count += static_cast<size_t>(n);
        if (count == bytes.size()) return HostFileResult::Invalid;
    }
    return HostFileResult::Invalid;
}
}
