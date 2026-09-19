#pragma once
#include <algorithm>
#include <cstdint>
#include <string>
#include <utility>
#if defined(_WIN32)
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#else
#include <cerrno>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#endif

namespace Switch2Kit {
enum class HostFileResult { OK, Missing, Invalid };
/** Explicit host settings/calibration reads only. No default path, persistence,
 * watcher or Bluetooth work. Reject special files via the opened handle,
 * bound paths/bytes/retries, and leave the caller's output unchanged on failure. */
inline HostFileResult readHostFile(const std::string& path, size_t limit, std::string& output) {
    if (path.empty() || path.size() > 4096 || path.find('\0') != std::string::npos ||
        !limit || limit > 524288) return HostFileResult::Invalid;
    if (std::any_of(path.begin(), path.end(), [](unsigned char c) { return c < 32 || c == 127; }))
        return HostFileResult::Invalid; // Host INI/XML selections must round-trip without injected records.
#if defined(_WIN32)
    // Accept UTF-8 host paths, not ANSI-code-page truncation or device namespaces.
    auto normalized = path;
    std::replace(normalized.begin(), normalized.end(), '/', '\\');
    if (normalized.rfind("\\\\.\\", 0) == 0 || normalized.rfind("\\\\?\\", 0) == 0 ||
        normalized.rfind("\\??\\", 0) == 0) return HostFileResult::Invalid;
    const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path.data(),
                                         static_cast<int>(path.size()), nullptr, 0);
    if (!length) return HostFileResult::Invalid;
    std::wstring wide(static_cast<size_t>(length), L'\0');
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path.data(),
                           static_cast<int>(path.size()), wide.data(), length) != length)
        return HostFileResult::Invalid;
    // Allow atomic replacement of settings, but not concurrent in-place writes.
    const HANDLE file = CreateFileW(wide.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_DELETE,
                                    nullptr, OPEN_EXISTING, FILE_FLAG_SEQUENTIAL_SCAN, nullptr);
    if (file == INVALID_HANDLE_VALUE) {
        const auto error = GetLastError();
        return error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND ?
            HostFileResult::Missing : HostFileResult::Invalid;
    }
    struct Close { HANDLE file; ~Close() { CloseHandle(file); } } close{file};
    BY_HANDLE_FILE_INFORMATION info{};
    LARGE_INTEGER size{};
    if (GetFileType(file) != FILE_TYPE_DISK || !GetFileInformationByHandle(file, &info) ||
        (info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) || !GetFileSizeEx(file, &size) ||
        size.QuadPart < 0 || static_cast<uint64_t>(size.QuadPart) > limit)
        return HostFileResult::Invalid;
    const auto expected = static_cast<size_t>(size.QuadPart);
#else
    const int fd = ::open(path.c_str(), O_RDONLY | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) return errno == ENOENT ? HostFileResult::Missing : HostFileResult::Invalid;
    struct Close { int fd; ~Close() { ::close(fd); } } close{fd};
    struct stat info{};
    if (::fstat(fd, &info) != 0 || !S_ISREG(info.st_mode) || info.st_size < 0 ||
        static_cast<uint64_t>(info.st_size) > limit) return HostFileResult::Invalid;
    const auto expected = static_cast<size_t>(info.st_size);
#endif
    std::string bytes(expected + 1, '\0');
    size_t count = 0;
    for (unsigned attempts = 0; attempts < 32; ++attempts) {
#if defined(_WIN32)
        DWORD n = 0;
        if (!ReadFile(file, bytes.data() + count, static_cast<DWORD>(bytes.size() - count), &n, nullptr))
            return HostFileResult::Invalid;
#else
        const auto n = ::read(fd, bytes.data() + count, bytes.size() - count);
        if (n < 0) { if (errno == EINTR) continue; return HostFileResult::Invalid; }
#endif
        if (!n) {
            if (count != expected) return HostFileResult::Invalid;
            bytes.resize(count); output = std::move(bytes); return HostFileResult::OK;
        }
        count += static_cast<size_t>(n);
        if (count == bytes.size()) return HostFileResult::Invalid;
    }
    return HostFileResult::Invalid;
}
}
