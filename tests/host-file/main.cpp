#include "../../Integrations/Emulators/HostFile.hpp"
#include <cassert>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <iostream>

int main() {
    namespace fs = std::filesystem;
    using Switch2Kit::HostFileResult;
    using Switch2Kit::readHostFile;
    const auto root = fs::temp_directory_path() / ("s2k-host-file-" +
        std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
    assert(fs::create_directory(root)); // Never reuse or erase an existing user directory.
    struct Cleanup { fs::path path; ~Cleanup() { fs::remove_all(path); } } cleanup{root};
    const auto file = root / fs::u8path(u8"controller-\u00e9-\u65e5.txt");
    const auto name = file.u8string();
    std::string output = "unchanged";
    const auto reject = [&](const std::string& path, size_t limit, HostFileResult expected) {
        output = "unchanged";
        assert(readHostFile(path, limit, output) == expected);
        assert(output == "unchanged");
    };
    reject(name, 4, HostFileResult::Missing);
    { std::ofstream stream(file, std::ios::binary); stream << "ABCD"; assert(stream.good()); }
    assert(readHostFile(name, 4, output) == HostFileResult::OK && output == "ABCD");
    reject(name, 3, HostFileResult::Invalid);
    reject(name, 0, HostFileResult::Invalid);
    reject(name, 524289, HostFileResult::Invalid);
    reject("", 4, HostFileResult::Invalid);
    reject(std::string(4097, 'x'), 4, HostFileResult::Invalid);
    reject(name + std::string("\0suffix", 7), 4, HostFileResult::Invalid);
    reject(name + "\n", 4, HostFileResult::Invalid);
    reject(root.u8string(), 4, HostFileResult::Invalid);
    { std::ofstream stream(file, std::ios::binary | std::ios::trunc); }
    assert(readHostFile(name, 4, output) == HostFileResult::OK && output.empty());
#if defined(_WIN32)
    reject("NUL", 4, HostFileResult::Invalid);
    reject("\\\\.\\PhysicalDrive0", 4, HostFileResult::Invalid);
    reject("//./pipe/s2k-test", 4, HostFileResult::Invalid);
    reject(std::string("\xff", 1), 4, HostFileResult::Invalid);
#else
    const auto fifo = root / "fifo";
    assert(mkfifo(fifo.c_str(), 0600) == 0);
    reject(fifo.string(), 4, HostFileResult::Invalid);
    reject("/dev/null", 4, HostFileResult::Invalid);
#endif
    std::cout << "PASS bounded UTF-8 regular-file reads, missing/special files and unchanged error outputs\n";
}
