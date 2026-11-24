#include "common.h"
#include <cstdarg>
#include <cstdio>
#include <mutex>

static std::wstring g_logPath;
static std::mutex g_logLock;

void LogOpen(const std::wstring& path) {
    g_logPath = path;
    FILE* f = _wfopen(path.c_str(), L"w");
    if (f) fclose(f);
}

void Log(const char* fmt, ...) {
    if (g_logPath.empty()) return;
    std::lock_guard<std::mutex> lock(g_logLock);
    FILE* f = _wfopen(g_logPath.c_str(), L"a");
    if (!f) return;
    SYSTEMTIME t;
    GetLocalTime(&t);
    fprintf(f, "%02d:%02d:%02d ", t.wHour, t.wMinute, t.wSecond);
    va_list ap;
    va_start(ap, fmt);
    vfprintf(f, fmt, ap);
    va_end(ap);
    fputc('\n', f);
    fclose(f);
}

bool ReadWholeFile(const std::wstring& path, Bytes& out) {
    // Shared access: the game may hold its save open while we read it.
    HANDLE h = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                           nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) return false;
    LARGE_INTEGER size;
    bool ok = GetFileSizeEx(h, &size) && size.QuadPart < (1LL << 31);
    if (ok) {
        out.resize((size_t)size.QuadPart);
        DWORD got = 0;
        ok = out.empty() || (ReadFile(h, out.data(), (DWORD)out.size(), &got, nullptr) && got == out.size());
    }
    CloseHandle(h);
    return ok;
}

bool WriteFileAtomic(const std::wstring& path, const std::string& data) {
    std::wstring tmp = path + L".tmp";
    FILE* f = _wfopen(tmp.c_str(), L"wb");
    if (!f) return false;
    bool ok = fwrite(data.data(), 1, data.size(), f) == data.size();
    ok = (fclose(f) == 0) && ok;
    return ok && MoveFileExW(tmp.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING);
}

bool FileStamp(const std::wstring& path, uint64_t& size, uint64_t& mtime) {
    WIN32_FILE_ATTRIBUTE_DATA a;
    if (!GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &a)) return false;
    size = ((uint64_t)a.nFileSizeHigh << 32) | a.nFileSizeLow;
    mtime = ((uint64_t)a.ftLastWriteTime.dwHighDateTime << 32) | a.ftLastWriteTime.dwLowDateTime;
    return true;
}

std::wstring DirName(const std::wstring& path) {
    size_t p = path.find_last_of(L"\\/");
    return p == std::wstring::npos ? L"." : path.substr(0, p);
}

std::string Narrow(const std::wstring& s) {
    int n = WideCharToMultiByte(CP_UTF8, 0, s.c_str(), (int)s.size(), nullptr, 0, nullptr, nullptr);
    std::string r(n, '\0');
    WideCharToMultiByte(CP_UTF8, 0, s.c_str(), (int)s.size(), &r[0], n, nullptr, nullptr);
    return r;
}
