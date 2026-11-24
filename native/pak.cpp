// Reads the treasure placement table out of the game's .pak files.
//
// The game data XMLs live in an encrypted, Oodle-compressed pak. This game uses a customised pak
// format (version 101): the index is the UE 5.3 layout, but numbers in it are XOR-masked with a
// single byte and every string is XOR-masked with its own byte (the masked value of its terminating
// zero). The AES key is assembled in the executable by a run of "mov dword ptr [reg+disp], imm32".
#include "common.h"
#include <algorithm>
#include <array>
#include <cstdio>
#include <cstring>
#include <map>

int Kraken_Decompress(const uint8_t* src, size_t src_len, uint8_t* dst, size_t dst_len);  // ooz

static const char* kTargetFile = "SectionTreasureBoxData.xml";

// ---------------------------------------------------------------- AES key from the executable

struct Mov { size_t pos, len; int reg, disp; uint32_t imm; };

static bool DecodeMov(const uint8_t* d, size_t n, size_t i, Mov& m) {
    size_t p = i;
    int rex = 0;
    if (p < n && d[p] == 0x41) { rex = 8; p++; }
    if (p + 2 >= n || d[p] != 0xC7) return false;
    uint8_t modrm = d[p + 1];
    int mod = modrm >> 6, op = (modrm >> 3) & 7, rm = modrm & 7;
    if (op != 0) return false;
    size_t q = p + 2;
    int disp;
    if (mod == 0 && rm != 4 && rm != 5) disp = 0;
    else if (mod == 1 || mod == 2) {
        if (rm == 4) { if (q >= n || d[q] != 0x24) return false; q++; }
        if (mod == 1) { if (q >= n) return false; disp = (int8_t)d[q]; q += 1; }
        else { if (q + 4 > n) return false; int32_t v; memcpy(&v, d + q, 4); disp = v; q += 4; }
    } else return false;
    if (q + 4 > n) return false;
    memcpy(&m.imm, d + q, 4);
    m.pos = i; m.len = q + 4 - i; m.reg = rm + rex; m.disp = disp;
    return true;
}

static std::vector<std::array<uint8_t, 32>> KeyCandidates(const Bytes& exe) {
    std::vector<std::array<uint8_t, 32>> out;
    std::map<std::string, bool> seen;
    const uint8_t* d = exe.data();
    size_t n = exe.size();
    auto add = [&](const uint32_t* w) {
        std::array<uint8_t, 32> k;
        memcpy(k.data(), w, 32);
        std::string s((const char*)k.data(), 32);
        if (!seen[s]) { seen[s] = true; out.push_back(k); }
    };
    for (size_t i = 0; i + 8 < n; i++) {
        Mov m;
        if (!DecodeMov(d, n, i, m)) continue;
        std::vector<uint32_t> order;
        std::map<int, uint32_t> byDisp;
        int reg = m.reg;
        for (;;) {
            order.push_back(m.imm);
            if (!byDisp.count(m.disp)) byDisp[m.disp] = m.imm;
            size_t next = m.pos + m.len;
            bool found = false;
            for (size_t g = 0; g <= 12 && next + g < n; g++) {
                Mov m2;
                if (DecodeMov(d, n, next + g, m2) && m2.reg == reg) { m = m2; found = true; break; }
            }
            if (!found || order.size() > 40) break;
        }
        if (order.size() < 8) continue;
        for (size_t s = 0; s + 8 <= order.size(); s++) add(&order[s]);
        for (auto& kv : byDisp) {
            uint32_t w[8];
            bool all = true;
            for (int k = 0; k < 8 && all; k++) {
                auto it = byDisp.find(kv.first + 4 * k);
                if (it == byDisp.end()) all = false; else w[k] = it->second;
            }
            if (all) add(w);
        }
    }
    return out;
}

// A correctly decrypted index starts with the masked mount point "../../../".
static bool LooksLikeIndex(const uint8_t* p) {
    if (p[1] != p[3] || p[2] != p[3]) return false;
    int len = p[0] ^ p[3];
    if (len < 4) return false;
    return p[4] == p[5] && p[4] == p[7] && p[4] == p[8] && p[6] == p[9] && (p[4] ^ p[6]) == ('.' ^ '/');
}

// ---------------------------------------------------------------- pak structures

struct PakFile {
    std::wstring path;
    FILE* f = nullptr;
    bool encryptedIndex = false;
    uint32_t version = 0;
    uint64_t indexOffset = 0, indexSize = 0;
    ~PakFile() { if (f) fclose(f); }
    bool Read(uint64_t off, void* buf, size_t len) {
        return _fseeki64(f, (int64_t)off, SEEK_SET) == 0 && fread(buf, 1, len, f) == len;
    }
    bool Open() {
        f = _wfopen(path.c_str(), L"rb");
        if (!f) return false;
        _fseeki64(f, 0, SEEK_END);
        int64_t size = _ftelli64(f);
        uint8_t tail[512];
        size_t n = (size_t)std::min<int64_t>(size, sizeof tail);
        if (!Read(size - n, tail, n)) return false;
        for (size_t i = n - 44; i > 0; i--) {
            uint32_t magic;
            memcpy(&magic, tail + i, 4);
            if (magic != 0x5A6F12E1) continue;
            encryptedIndex = tail[i - 1] != 0;
            memcpy(&version, tail + i + 4, 4);
            memcpy(&indexOffset, tail + i + 8, 8);
            memcpy(&indexSize, tail + i + 16, 8);
            return indexOffset + indexSize <= (uint64_t)size;
        }
        return false;
    }
    bool ReadBlock(uint64_t off, uint64_t size, const uint8_t* key, Bytes& out) {
        uint64_t padded = encryptedIndex ? (size + 15) / 16 * 16 : size;
        out.resize((size_t)padded);
        if (!Read(off, out.data(), out.size())) return false;
        return !encryptedIndex || AesEcbDecrypt(key, out.data(), out.size());
    }
};

struct MaskedReader {
    const uint8_t* d; size_t n, p = 0; uint8_t mask; bool ok = true;
    MaskedReader(const uint8_t* data, size_t size, uint8_t m) : d(data), n(size), mask(m) {}
    bool Need(size_t k) { if (p + k > n) ok = false; return ok; }
    uint64_t Num(int bytes) {
        if (!Need(bytes)) return 0;
        uint64_t v = 0;
        for (int i = 0; i < bytes; i++) v |= (uint64_t)(uint8_t)(d[p + i] ^ mask) << (8 * i);
        p += bytes;
        return v;
    }
    int32_t I32() { return (int32_t)Num(4); }
    int64_t I64() { return (int64_t)Num(8); }
    void Skip(size_t k) { if (Need(k)) p += k; }
    std::string Str() {
        int32_t len = I32();
        if (len == 0) return std::string();
        size_t bytes = len > 0 ? (size_t)len : (size_t)(-len) * 2;
        if (!Need(bytes)) return std::string();
        std::string s;
        uint8_t m = d[p + bytes - 1];
        if (len > 0) { for (size_t i = 0; i + 1 < bytes; i++) s.push_back((char)(d[p + i] ^ m)); }
        else { for (size_t i = 0; i + 2 < bytes; i += 2) s.push_back((char)(d[p + i] ^ m)); }
        p += bytes;
        return s;
    }
};

static bool IEquals(const std::string& a, const char* b) {
    return _stricmp(a.c_str(), b) == 0;
}

// Finds the target file in this pak; returns its encoded-entry bytes position.
static bool FindEntry(PakFile& pak, const uint8_t* key, Bytes& index, size_t& encodedBase, size_t& encodedSize, int32_t& entryOffset) {
    if (!pak.ReadBlock(pak.indexOffset, pak.indexSize, key, index) || index.size() < 16) return false;
    uint8_t numMask = index[3];
    MaskedReader r(index.data(), index.size(), numMask);
    r.Str();                   // mount point
    r.I32();                   // entry count
    r.Skip(8);                 // path hash seed
    if (r.I32()) { r.Skip(16 + 20); }
    if (!r.I32()) return false;            // needs the full directory index
    int64_t fdiOff = r.I64(), fdiSize = r.I64();
    r.Skip(20);
    int32_t encSize = r.I32();
    if (!r.ok || encSize < 0 || r.p + (size_t)encSize > index.size()) return false;
    encodedBase = r.p;
    encodedSize = (size_t)encSize;

    Bytes fdi;
    if (!pak.ReadBlock((uint64_t)fdiOff, (uint64_t)fdiSize, key, fdi)) return false;
    MaskedReader dr(fdi.data(), fdi.size(), numMask);
    int32_t dirs = dr.I32();
    for (int32_t i = 0; i < dirs && dr.ok; i++) {
        dr.Str();
        int32_t files = dr.I32();
        for (int32_t j = 0; j < files && dr.ok; j++) {
            std::string name = dr.Str();
            int32_t off = dr.I32();
            if (dr.ok && IEquals(name, kTargetFile)) { entryOffset = off; return true; }
        }
    }
    return false;
}

static bool ExtractEntry(PakFile& pak, const uint8_t* key, const Bytes& index, size_t encodedBase, size_t encodedSize, int32_t entryOffset, Bytes& out, std::string& err) {
    // The encoded entries use their own mask: the most common byte (zero bits dominate).
    size_t counts[256] = {0};
    for (size_t i = 0; i < encodedSize; i++) counts[index[encodedBase + i]]++;
    uint8_t mask = (uint8_t)(std::max_element(counts, counts + 256) - counts);
    MaskedReader r(index.data() + encodedBase, encodedSize, mask);
    r.p = (size_t)entryOffset;
    uint32_t flags = (uint32_t)r.Num(4);
    uint32_t blockSize = (flags & 0x3f) << 11;
    if ((flags & 0x3f) == 0x3f) blockSize = (uint32_t)r.Num(4);
    bool encrypted = (flags >> 22) & 1;
    uint32_t method = (flags >> 23) & 0x3f;
    uint64_t offset = ((flags >> 31) & 1) ? r.Num(4) : r.Num(8);
    uint64_t usize = ((flags >> 30) & 1) ? r.Num(4) : r.Num(8);
    if (!r.ok || usize == 0 || usize > (256u << 20)) { err = "bad pak entry"; return false; }

    // The data is preceded by an unmasked copy of the entry header that lists the block ranges.
    uint8_t hdr[48 + 4];
    if (!pak.Read(offset, hdr, sizeof hdr)) { err = "pak read failed"; return false; }
    uint32_t hdrMethod;
    memcpy(&hdrMethod, hdr + 24, 4);
    out.assign((size_t)usize + 64, 0);
    if (method == 0) {
        size_t start = 48 + 1 + 4;
        Bytes raw;
        uint64_t sz = encrypted ? (usize + 15) / 16 * 16 : usize;
        raw.resize((size_t)sz);
        if (!pak.Read(offset + start, raw.data(), raw.size())) { err = "pak read failed"; return false; }
        if (encrypted && !AesEcbDecrypt(key, raw.data(), raw.size())) { err = "decrypt failed"; return false; }
        memcpy(out.data(), raw.data(), (size_t)usize);
        out.resize((size_t)usize);
        return true;
    }
    uint32_t blocks;
    memcpy(&blocks, hdr + 48, 4);
    if (blocks == 0 || blocks > 100000) { err = "bad block count"; return false; }
    std::vector<uint64_t> ranges(blocks * 2);
    if (!pak.Read(offset + 52, ranges.data(), ranges.size() * 8)) { err = "pak read failed"; return false; }
    if (blockSize == 0) blockSize = (uint32_t)usize;
    uint64_t done = 0;
    Bytes in;
    for (uint32_t b = 0; b < blocks; b++) {
        uint64_t s = ranges[b * 2], e = ranges[b * 2 + 1];
        if (s < offset) { s += offset; e += offset; }   // relative block offsets (newer pak versions)
        uint64_t len = e - s, readLen = encrypted ? (len + 15) / 16 * 16 : len;
        in.resize((size_t)readLen);
        if (!pak.Read(s, in.data(), in.size())) { err = "pak read failed"; return false; }
        if (encrypted && !AesEcbDecrypt(key, in.data(), in.size())) { err = "decrypt failed"; return false; }
        uint64_t want = std::min<uint64_t>(blockSize, usize - done);
        int got = Kraken_Decompress(in.data(), (size_t)len, out.data() + done, (size_t)want);
        if (got != (int)want) { err = "decompression failed"; return false; }
        done += want;
    }
    out.resize((size_t)usize);
    return true;
}

// ---------------------------------------------------------------- catalog

static std::string Attr(const std::string& line, const char* name) {
    std::string pat = std::string(name) + "=\"";
    size_t p = 0;
    while ((p = line.find(pat, p)) != std::string::npos) {
        if (p == 0 || line[p - 1] == ':' || line[p - 1] == ' ') break;
        p += pat.size();
    }
    if (p == std::string::npos) return std::string();
    p += pat.size();
    size_t e = line.find('"', p);
    return e == std::string::npos ? std::string() : line.substr(p, e - p);
}

static bool IsNumber(const std::string& s) {
    if (s.empty()) return false;
    for (size_t i = 0; i < s.size(); i++) if (!(isdigit((unsigned char)s[i]) || (i == 0 && s[i] == '-'))) return false;
    return true;
}

static std::string KindOf(const std::string& uidName) {
    // "DT_<Kind>_G<n>_..." -> "<kind>"
    if (uidName.compare(0, 3, "DT_") != 0) return std::string();
    size_t e = uidName.find("_G", 3);
    if (e == std::string::npos) return std::string();
    std::string k = uidName.substr(3, e - 3);
    for (char& c : k) { if (!isalpha((unsigned char)c)) return std::string(); c = (char)tolower((unsigned char)c); }
    return k;
}

std::string GameDataVersion(const std::wstring& exePath, const std::wstring& pakDir) {
    uint64_t h = 1469598103934665603ULL;
    auto mix = [&](uint64_t v) { for (int i = 0; i < 8; i++) { h ^= (v >> (8 * i)) & 0xff; h *= 1099511628211ULL; } };
    uint64_t size, mtime;
    if (FileStamp(exePath, size, mtime)) { mix(size); mix(mtime); }
    WIN32_FIND_DATAW fd;
    HANDLE f = FindFirstFileW((pakDir + L"\\*.pak").c_str(), &fd);
    if (f != INVALID_HANDLE_VALUE) {
        do { mix(((uint64_t)fd.nFileSizeHigh << 32) | fd.nFileSizeLow); mix(((uint64_t)fd.ftLastWriteTime.dwHighDateTime << 32) | fd.ftLastWriteTime.dwLowDateTime); }
        while (FindNextFileW(f, &fd));
        FindClose(f);
    }
    char buf[32];
    snprintf(buf, sizeof buf, "%016llx", (unsigned long long)h);
    return buf;
}

bool BuildTreasureCatalog(const std::wstring& exePath, const std::wstring& pakDir, const std::wstring& outFile, const std::string& version, std::string& err) {
    // Smallest paks first: the data tables are in a small one.
    std::vector<std::pair<uint64_t, std::wstring>> paks;
    WIN32_FIND_DATAW fd;
    HANDLE fh = FindFirstFileW((pakDir + L"\\*.pak").c_str(), &fd);
    if (fh == INVALID_HANDLE_VALUE) { err = "no pak files found"; return false; }
    do paks.push_back({((uint64_t)fd.nFileSizeHigh << 32) | fd.nFileSizeLow, pakDir + L"\\" + fd.cFileName});
    while (FindNextFileW(fh, &fd));
    FindClose(fh);
    std::sort(paks.begin(), paks.end());

    Bytes exe;
    if (!ReadWholeFile(exePath, exe)) { err = "cannot read the game executable"; return false; }
    auto candidates = KeyCandidates(exe);
    exe.clear(); exe.shrink_to_fit();
    Log("AES key candidates: %zu", candidates.size());

    std::array<uint8_t, 32> key{};
    bool haveKey = false;
    for (auto& p : paks) {
        PakFile pak;
        pak.path = p.second;
        if (!pak.Open()) continue;
        if (pak.encryptedIndex && !haveKey) {
            uint8_t first[32];
            if (!pak.Read(pak.indexOffset, first, 32)) continue;
            for (auto& c : candidates) {
                uint8_t t[32];
                memcpy(t, first, 32);
                if (AesEcbDecrypt(c.data(), t, 32) && LooksLikeIndex(t)) { key = c; haveKey = true; break; }
            }
            if (!haveKey) { err = "AES key not found"; return false; }
            Log("AES key found (pak version %u)", pak.version);
        }
        Bytes index;
        size_t encBase = 0, encSize = 0;
        int32_t entry = 0;
        if (!FindEntry(pak, key.data(), index, encBase, encSize, entry)) continue;
        Log("%s found in %s", kTargetFile, Narrow(p.second.substr(p.second.find_last_of(L"\\") + 1)).c_str());
        Bytes xml;
        if (!ExtractEntry(pak, key.data(), index, encBase, encSize, entry, xml, err)) return false;

        std::string text((const char*)xml.data(), xml.size()), lua;
        lua.reserve(text.size() / 3);
        lua += "-- Generated by DragonSword Radar from the local game files.\nreturn {version=\"" + version + "\",list={\n";
        size_t count = 0, pos = 0;
        while ((pos = text.find("SectionActorData ", pos)) != std::string::npos) {
            size_t end = text.find("/>", pos);
            if (end == std::string::npos) break;
            std::string line = text.substr(pos, end - pos);
            pos = end;
            std::string id = Attr(line, "CID"), sec = Attr(line, "SectionUID"), x = Attr(line, "PosX"), y = Attr(line, "PosY"), z = Attr(line, "PosZ");
            if (!IsNumber(id) || !IsNumber(sec) || sec.size() < 3 || !IsNumber(x) || !IsNumber(y) || !IsNumber(z)) continue;
            int map = atoi(sec.substr(sec.size() - 3).c_str());
            lua += "{id=" + id + ",map=" + std::to_string(map) + ",x=" + x + ",y=" + y + ",z=" + z + ",kind=\"" + KindOf(Attr(line, "UIDName")) + "\"},\n";
            count++;
        }
        lua += "}}\n";
        if (count == 0) { err = "treasure table was empty"; return false; }
        if (!WriteFileAtomic(outFile, lua)) { err = "cannot write the catalog"; return false; }
        Log("treasure catalog written: %zu chests", count);
        return true;
    }
    err = haveKey ? "treasure table not found in the paks" : "no encrypted pak found";
    return false;
}
