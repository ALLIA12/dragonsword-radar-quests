// Reads the game's save database (SQLCipher 4 defaults: PBKDF2-HMAC-SHA512 with 256000 iterations,
// AES-256-CBC pages, HMAC-SHA512 per page) with a small built-in SQLite table reader.
//
// The passphrase is a 20-digit number the game keeps in memory while a save is loaded; candidates
// are collected from the process memory and each one is checked against the save's first page.
#include "common.h"
#include <algorithm>
#include <cstring>
#include <functional>
#include <map>
#include <unordered_map>

namespace {

const uint32_t kKdfIterations = 256000;
const size_t kReserve = 80;   // IV (16) + HMAC-SHA512 (64)

struct Keys { uint8_t enc[32], mac[32]; };

bool DeriveKeys(const Bytes& file, const std::string& pass, Keys& k) {
    if (file.size() < 4096) return false;
    if (!Pbkdf2Sha512((const uint8_t*)pass.data(), pass.size(), file.data(), 16, kKdfIterations, k.enc, 32)) return false;
    uint8_t macSalt[16];
    for (int i = 0; i < 16; i++) macSalt[i] = file[i] ^ 0x3a;
    return Pbkdf2Sha512(k.enc, 32, macSalt, 16, 2, k.mac, 32);
}

bool PageMacOk(const uint8_t* page, size_t ps, uint32_t pgno, const Keys& k) {
    size_t start = pgno == 1 ? 16 : 0;
    uint8_t mac[64];
    if (!HmacSha512(k.mac, 32, page + start, ps - 64 - start, (const uint8_t*)&pgno, 4, mac)) return false;
    return memcmp(mac, page + ps - 64, 64) == 0;
}

// Derived keys are cached per (salt, passphrase): deriving them takes a noticeable fraction of a second.
std::map<std::string, Keys> g_keyCache;

bool KeysFor(const Bytes& file, const std::string& pass, Keys& k) {
    std::string id = std::string((const char*)file.data(), 16) + pass;
    auto it = g_keyCache.find(id);
    if (it != g_keyCache.end()) { k = it->second; return true; }
    if (!DeriveKeys(file, pass, k)) return false;
    if (!PageMacOk(file.data(), 4096, 1, k)) return false;
    g_keyCache[id] = k;
    return true;
}

struct Db {
    const Bytes& file;
    Keys keys;
    size_t ps = 4096, usable = 4096 - kReserve;
    std::unordered_map<uint32_t, Bytes> pages;
    bool corrupt = false;
    Db(const Bytes& f, const Keys& k) : file(f), keys(k) {}

    const uint8_t* Page(uint32_t n) {
        auto it = pages.find(n);
        if (it != pages.end()) return it->second.data();
        size_t off = (size_t)(n - 1) * ps;
        if (n == 0 || off + ps > file.size()) { corrupt = true; return nullptr; }
        const uint8_t* raw = file.data() + off;
        if (!PageMacOk(raw, ps, n, keys)) { corrupt = true; return nullptr; }
        Bytes plain(ps, 0);
        size_t start = n == 1 ? 16 : 0;
        if (!AesCbcDecrypt(keys.enc, raw + ps - kReserve, raw + start, plain.data() + start, ps - kReserve - start)) { corrupt = true; return nullptr; }
        if (n == 1) memcpy(plain.data(), "SQLite format 3", 16);
        return (pages[n] = std::move(plain)).data();
    }
};

uint64_t Varint(const uint8_t* p, size_t& i) {
    uint64_t v = 0;
    for (int k = 0; k < 8; k++) {
        uint8_t b = p[i++];
        v = (v << 7) | (b & 0x7f);
        if (!(b & 0x80)) return v;
    }
    return (v << 8) | p[i++];
}

uint32_t Be(const uint8_t* p, int n) { uint32_t v = 0; for (int i = 0; i < n; i++) v = (v << 8) | p[i]; return v; }

struct Value { bool isInt = false, isText = false; int64_t i = 0; std::string s; };

std::vector<Value> DecodeRecord(const Bytes& rec) {
    std::vector<Value> out;
    if (rec.empty()) return out;
    size_t i = 0;
    uint64_t hdrLen = Varint(rec.data(), i);
    std::vector<uint64_t> types;
    while (i < hdrLen && i < rec.size()) types.push_back(Varint(rec.data(), i));
    size_t p = (size_t)hdrLen;
    for (uint64_t t : types) {
        Value v;
        static const int sizes[] = {0, 1, 2, 3, 4, 6, 8, 8, 0, 0};
        if (t <= 9) {
            int n = sizes[t];
            if (p + n > rec.size()) break;
            if (t >= 1 && t <= 6) {
                uint64_t u = 0;
                for (int k = 0; k < n; k++) u = (u << 8) | rec[p + k];
                int shift = 64 - 8 * n;
                v.i = (int64_t)(u << shift) >> shift;
                v.isInt = true;
            } else if (t == 8 || t == 9) { v.i = (int64_t)(t - 8); v.isInt = true; }
            p += n;
        } else {
            size_t n = (size_t)((t - (t % 2 ? 13 : 12)) / 2);
            if (p + n > rec.size()) break;
            if (t % 2) { v.isText = true; v.s.assign((const char*)rec.data() + p, n); }
            p += n;
        }
        out.push_back(v);
    }
    return out;
}

// Walks a table b-tree and hands every row's record to `fn`.
void WalkTable(Db& db, uint32_t root, const std::function<void(const Bytes&)>& fn, int depth = 0) {
    if (depth > 20) return;
    const uint8_t* page = db.Page(root);
    if (!page) return;
    size_t h = root == 1 ? 100 : 0;
    uint8_t type = page[h];
    uint32_t cells = Be(page + h + 3, 2);
    size_t ptrs = h + (type == 0x05 ? 12 : 8);
    for (uint32_t c = 0; c < cells && !db.corrupt; c++) {
        size_t cell = Be(page + ptrs + 2 * c, 2);
        if (cell >= db.ps) { db.corrupt = true; return; }
        if (type == 0x05) {
            WalkTable(db, Be(page + cell, 4), fn, depth + 1);
            page = db.Page(root);   // the page cache may have rehashed
            if (!page) return;
        } else if (type == 0x0D) {
            size_t i = cell;
            uint64_t payload = Varint(page, i);
            Varint(page, i);   // rowid
            size_t x = db.usable - 35, local = (size_t)payload;
            if (payload > x) {
                size_t m = ((db.usable - 12) * 32 / 255) - 23;
                size_t k = m + (size_t)((payload - m) % (db.usable - 4));
                local = k <= x ? k : m;
            }
            Bytes rec(page + i, page + i + local);
            if (payload > local) {
                uint32_t next = Be(page + i + local, 4);
                while (next && rec.size() < payload && !db.corrupt) {
                    const uint8_t* ov = db.Page(next);
                    if (!ov) return;
                    size_t take = std::min<size_t>(db.usable - 4, (size_t)payload - rec.size());
                    rec.insert(rec.end(), ov + 4, ov + 4 + take);
                    next = Be(ov, 4);
                }
                page = db.Page(root);
                if (!page) return;
            }
            fn(rec);
        } else return;
    }
    if (type == 0x05 && !db.corrupt) WalkTable(db, Be(page + h + 8, 4), fn, depth + 1);
}

// Column position of `name` in a CREATE TABLE statement.
int ColumnIndex(const std::string& sql, const char* name) {
    size_t open = sql.find('('), close = sql.rfind(')');
    if (open == std::string::npos || close == std::string::npos) return -1;
    std::string body = sql.substr(open + 1, close - open - 1);
    int idx = 0, depth = 0;
    size_t start = 0;
    for (size_t i = 0; i <= body.size(); i++) {
        char c = i < body.size() ? body[i] : ',';
        if (c == '(') depth++;
        else if (c == ')') depth--;
        else if (c == ',' && depth == 0) {
            std::string part = body.substr(start, i - start);
            size_t a = part.find_first_not_of(" \t\r\n\"`[");
            size_t b = part.find_first_of(" \t\r\n\"`]", a);
            std::string col = a == std::string::npos ? "" : part.substr(a, b - a);
            if (_stricmp(col.c_str(), "PRIMARY") == 0 || _stricmp(col.c_str(), "UNIQUE") == 0 || _stricmp(col.c_str(), "CONSTRAINT") == 0) break;
            if (_stricmp(col.c_str(), name) == 0) return idx;
            idx++;
            start = i + 1;
        }
    }
    return -1;
}

}  // namespace

bool SaveKeyMatches(const Bytes& file, const std::string& passphrase) {
    Keys k;
    return KeysFor(file, passphrase, k);
}

SaveResult ReadSave(const Bytes& file, const std::string& passphrase, SaveState& out, std::string& err) {
    Keys k;
    if (file.size() < 4096 || file.size() % 4096 != 0) { err = "save file is incomplete"; return SAVE_BUSY; }
    if (!KeysFor(file, passphrase, k)) return SAVE_BAD_KEY;
    Db db(file, k);
    const uint8_t* p1 = db.Page(1);
    if (!p1) return SAVE_BUSY;
    db.ps = Be(p1 + 16, 2) == 1 ? 65536 : Be(p1 + 16, 2);
    if (db.ps != 4096) { err = "unexpected page size"; return SAVE_ERROR; }
    db.usable = db.ps - p1[20];

    struct Table { uint32_t root = 0; std::string sql; };
    std::map<std::string, Table> tables;
    WalkTable(db, 1, [&](const Bytes& rec) {
        auto v = DecodeRecord(rec);
        if (v.size() >= 5 && v[0].s == "table" && v[3].isInt) tables[v[1].s] = Table{(uint32_t)v[3].i, v[4].s};
    });
    if (db.corrupt) return SAVE_BUSY;

    out = SaveState();
    auto chests = tables.find("tb_treasure_box");
    if (chests == tables.end()) { err = "tb_treasure_box missing"; return SAVE_ERROR; }
    int catCol = ColumnIndex(chests->second.sql, "CATEGORY"), bitCol = ColumnIndex(chests->second.sql, "OPENED_BIT_FIELD");
    if (catCol < 0 || bitCol < 0) { err = "unexpected tb_treasure_box layout"; return SAVE_ERROR; }
    WalkTable(db, chests->second.root, [&](const Bytes& rec) {
        auto v = DecodeRecord(rec);
        if ((int)v.size() <= std::max(catCol, bitCol) || !v[catCol].isInt || !v[bitCol].isInt) return;
        uint64_t bits = (uint64_t)v[bitCol].i;
        for (int b = 0; b < 64; b++) if ((bits >> b) & 1) out.openedChests.push_back(v[catCol].i * 64 + b);
    });

    auto quests = tables.find("tb_dynamic_quest_complete");
    if (quests != tables.end()) {
        int idCol = ColumnIndex(quests->second.sql, "QUEST_ID"), cntCol = ColumnIndex(quests->second.sql, "COMPLETE_CNT");
        if (idCol >= 0) WalkTable(db, quests->second.root, [&](const Bytes& rec) {
            auto v = DecodeRecord(rec);
            if ((int)v.size() <= idCol || !v[idCol].isInt) return;
            if (cntCol >= 0 && (int)v.size() > cntCol && v[cntCol].isInt && v[cntCol].i <= 0) return;
            out.finishedQuests.push_back(v[idCol].i);
        });
    }
    if (db.corrupt) return SAVE_BUSY;
    return SAVE_OK;
}

// Collects runs of exactly 20 ASCII or UTF-16 digits from this process's writable memory, most
// frequent first.
std::vector<std::string> FindKeyCandidates(size_t maxCandidates) {
    const size_t kLen = 20;
    std::unordered_map<std::string, int> found;
    Bytes buf(4 << 20);
    HANDLE self = GetCurrentProcess();
    MEMORY_BASIC_INFORMATION mbi;
    uintptr_t addr = 0;
    auto note = [&](const uint8_t* p, bool wide) {
        std::string s;
        for (size_t k = 0; k < kLen; k++) s.push_back((char)p[wide ? 2 * k : k]);
        if (found.size() < 20000 || found.count(s)) found[s]++;
    };
    while (VirtualQuery((LPCVOID)addr, &mbi, sizeof mbi) == sizeof mbi) {
        uintptr_t base = (uintptr_t)mbi.BaseAddress;
        size_t size = mbi.RegionSize;
        if (mbi.State == MEM_COMMIT && mbi.Type == MEM_PRIVATE && mbi.Protect == PAGE_READWRITE) {
            for (size_t off = 0; off < size; off += buf.size()) {
                size_t n = std::min(buf.size(), size - off);
                SIZE_T got = 0;
                // ReadProcessMemory on ourselves cannot fault if a region is released meanwhile.
                if (!ReadProcessMemory(self, (LPCVOID)(base + off), buf.data(), n, &got) || got == 0) continue;
                const uint8_t* b = buf.data();
                size_t run = 0;
                for (size_t i = 0; i < got; i++) {
                    if (b[i] >= '0' && b[i] <= '9') { run++; continue; }
                    if (run == kLen && b[i] == 0) note(b + i - kLen, false);
                    run = 0;
                }
                run = 0;
                for (size_t i = 0; i + 1 < got; i += 2) {
                    if (b[i + 1] == 0 && b[i] >= '0' && b[i] <= '9') { run++; continue; }
                    if (run == kLen && b[i] == 0 && b[i + 1] == 0) note(b + i - 2 * kLen, true);
                    run = 0;
                }
            }
        }
        uintptr_t next = base + size;
        if (next <= addr) break;
        addr = next;
    }
    std::vector<std::pair<int, std::string>> sorted;
    for (auto& kv : found) sorted.push_back({-kv.second, kv.first});
    std::sort(sorted.begin(), sorted.end());
    std::vector<std::string> out;
    for (auto& s : sorted) { if (out.size() >= maxCandidates) break; out.push_back(s.second); }
    return out;
}
