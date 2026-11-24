# Radar quest sync (local addition to the Treasure Radar mod).
#
# The game only records finished random NPC quests in the save file; after a restart its live quest
# state no longer knows about them. This script reads that list from the save (read-only, the same
# way the radar reads opened treasure chests) and writes it to quest_state.lua next to this file,
# which the radar uses to hide markers for quests that are already done.
#
# Run it while the game is running with a save loaded. The radar picks the result up within seconds.
# It is only needed if markers for finished quests show up, for example after playing with the mod
# switched off; quests finished while the radar is running are remembered automatically.
$ErrorActionPreference = "Stop"
$mod = $PSScriptRoot
$saveRoot = Join-Path $mod "..\..\..\..\Saved\SaveGames"
$out = Join-Path $mod "quest_state.lua"

function Fail([string]$message) { Write-Host $message -ForegroundColor Yellow; exit 1 }

if (-not (Test-Path -LiteralPath $saveRoot)) { Fail "Save folder not found: $saveRoot" }
$game = Get-Process -Name "DSClient-Win64-Shipping" -ErrorAction SilentlyContinue | Sort-Object StartTime -Descending | Select-Object -First 1
if (-not $game) { Fail "The game is not running. Start it, load your save, then run this again." }
$database = Get-ChildItem -LiteralPath $saveRoot -Recurse -File | Where-Object { $_.Extension -in ".db", ".bak" } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $database) { Fail "No save database found under $saveRoot" }

if (-not ("RadarQuestSync.Native" -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
namespace RadarQuestSync {
    public static class Native {
        [DllImport("kernel32", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern IntPtr LoadLibrary(string path);
        [DllImport("e_sqlcipher.dll", CallingConvention = CallingConvention.Cdecl)]
        static extern int sqlite3_open_v2(byte[] filename, out IntPtr db, int flags, IntPtr vfs);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        delegate int ExecCallback(IntPtr context, int columnCount, IntPtr values, IntPtr names);
        [DllImport("e_sqlcipher.dll", CallingConvention = CallingConvention.Cdecl)]
        static extern int sqlite3_exec(IntPtr db, byte[] sql, ExecCallback callback, IntPtr context, out IntPtr error);
        [DllImport("e_sqlcipher.dll", CallingConvention = CallingConvention.Cdecl)]
        static extern int sqlite3_close_v2(IntPtr db);
        [DllImport("e_sqlcipher.dll", CallingConvention = CallingConvention.Cdecl)]
        static extern void sqlite3_free(IntPtr p);

        static byte[] Utf8(string s) { byte[] b = Encoding.UTF8.GetBytes(s); byte[] r = new byte[b.Length + 1]; Array.Copy(b, r, b.Length); return r; }
        static string Str(IntPtr p) {
            if (p == IntPtr.Zero) return null;
            int n = 0; while (Marshal.ReadByte(p, n) != 0) n++;
            byte[] b = new byte[n]; Marshal.Copy(p, b, 0, n); return Encoding.UTF8.GetString(b);
        }
        // Opens the save read-only (flag 1) and returns the first column of every result row.
        public static List<string> FirstColumn(string path, string key, string sql) {
            IntPtr db;
            int rc = sqlite3_open_v2(Utf8(path), out db, 1, IntPtr.Zero);
            if (rc != 0) { if (db != IntPtr.Zero) sqlite3_close_v2(db); throw new Exception("could not open the save database (code " + rc + ")"); }
            try {
                List<string> rows = new List<string>();
                ExecCallback cb = delegate(IntPtr ctx, int n, IntPtr values, IntPtr names) {
                    if (n > 0) rows.Add(Str(Marshal.ReadIntPtr(values, 0)));
                    return 0;
                };
                IntPtr err;
                string full = "PRAGMA key = '" + key.Replace("'", "''") + "';PRAGMA cipher_compatibility = 4;" + sql;
                rc = sqlite3_exec(db, Utf8(full), cb, IntPtr.Zero, out err);
                if (rc != 0) { string m = Str(err); if (err != IntPtr.Zero) sqlite3_free(err); throw new Exception("save database query failed (code " + rc + "): " + m); }
                GC.KeepAlive(cb);
                return rows;
            } finally { sqlite3_close_v2(db); }
        }
    }
}
'@
}
[void][RadarQuestSync.Native]::LoadLibrary((Join-Path $mod "e_sqlcipher.dll"))

# The radar's own reader locates the save key in the running game; it is used in memory only.
$asm = [Reflection.Assembly]::LoadFrom((Join-Path $mod "DragonSwordRadar.Managed.dll"))
$flags = [Reflection.BindingFlags]'Public,NonPublic,Static,Instance'
$readerType = $asm.GetType("DragonSwordTreasureRadar.SaveDatabaseKeyReader")
$stateType = $asm.GetType("DragonSwordTreasureRadar.TreasureSaveState")
if (-not $readerType -or -not $stateType) { Fail "This version of the radar mod is not supported by the quest sync." }
$reader = [Activator]::CreateInstance($readerType, $true)
$readBits = $stateType.GetMethod("ReadOpenedTreasureBits", $flags)
$read = $readerType.GetMethod("Read", $flags)
if (-not $readBits -or -not $read) { Fail "This version of the radar mod is not supported by the quest sync." }
$dbPath = $database.FullName
$validate = [Action[string]] { param($k) [void]$readBits.Invoke($null, [object[]]@([string]$dbPath, [string]$k)) }
try {
    $ret = $read.Invoke($reader, [object[]]@($game.PSObject.BaseObject, [string]$dbPath, $validate))
} catch {
    Fail ("Could not read the save key from the game. Load a save first, then run this again.`n" + $_.Exception.GetBaseException().Message)
}
$key = if ($ret -is [string] -and $ret) { $ret } else { $readerType.GetField("_key", $flags).GetValue($reader) }
if (-not $key) { Fail "Could not read the save key from the game. Load a save first, then run this again." }

$rows = [RadarQuestSync.Native]::FirstColumn($dbPath, $key, "SELECT QUEST_ID FROM tb_dynamic_quest_complete WHERE COMPLETE_CNT > 0 ORDER BY QUEST_ID")
$ids = @($rows | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int64]$_ } | Sort-Object -Unique)

$lines = @("-- Random NPC quests known to be completed. Maintained by the radar; see sync_completed_quests.ps1.", "return {done={")
foreach ($id in $ids) { $lines += "[$id]=true," }
$lines += "}}"
$tmp = "$out.tmp"
[IO.File]::WriteAllText($tmp, ($lines -join "`n"), (New-Object Text.UTF8Encoding $false))
Move-Item -LiteralPath $tmp -Destination $out -Force
Write-Host ("Completed random NPC quests found in the save ({0}): {1}" -f $database.Name, $ids.Count)
Write-Host "Wrote $out"
