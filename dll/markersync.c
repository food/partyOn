// markersync: native hook DLL for the Windrose dedicated server.
// Loaded from Lua via package.loadlib(path, "*"); hooks run from DllMain.
//
// Hooks R5NetBlServerReactorV2::RuleRequestServer. When a player adds, updates
// or removes a map marker, the same rule request is replayed for every other
// known player by swapping the PlayerId in the payload. MarkerIds stay equal
// across players, so a removal by anyone removes the marker for everyone.
// Online players get the replay through their own reactor (so the diff reaches
// their client), offline players through the sender's reactor (save only).
//
// Request layout (protobuf, ArenaStringPtr = tagged ptr to MSVC std::string):
//   +0x10 request id (32 hex)   +0x18 rule name   +0x20 payload
// Payload of PlayerInWorld rules: [u32 len][PlayerId][u32 len][IslandId][u32 len][MarkerId]...
// Session: vector<shared_ptr<Reactor>> at session+0x88 (begin) / +0x90 (end).
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include "MinHook.h"

#define RVA_RULE_REQUEST_SERVER 0x4ebf9d0  // R5NetBlServerReactorV2::RuleRequestServer
#define RVA_ADD_SERVER_REACTOR 0x4e1daf0   // R5NetBlSession::AddServerReactor
#define RVA_GET_ACCOUNT_ID 0x4e43c70       // reactor -> "account-id" from the client's gRPC metadata
// First 32 bytes of each target in game build 0.10.0.9.32. Any game update moves
// code, so a mismatch means: do not hook (a wrong address would crash the server).
#define SIG_RULE_REQUEST_SERVER "\x48\x89\x5c\x24\x18\x48\x89\x74\x24\x20\x57\x41\x54\x41\x55\x41\x56\x41\x57\x48\x81\xec\x50\x0d\x00\x00\x48\x8b\x05\x4f\xa8\x93"
#define SIG_ADD_SERVER_REACTOR "\x48\x89\x5c\x24\x18\x55\x56\x57\x41\x54\x41\x55\x41\x56\x41\x57\x48\x8d\xac\x24\x50\xfa\xff\xff\x48\x81\xec\xb0\x06\x00\x00\x48"
#define SIG_GET_ACCOUNT_ID "\x40\x53\x48\x81\xec\x80\x00\x00\x00\x48\x8b\x05\xc0\x65\x9b\x0a\x48\x33\xc4\x48\x89\x44\x24\x70\x48\x8b\xda\x48\x89\x54\x24\x28"
#define DATA_DIR "Z:\\home\\steam\\server-files\\windrose_plus_data\\"
#define ID_LEN 32
#define MAX_PLAYERS 64

typedef void *(*RuleRequestServer_t)(void *reactor, void *request, void *a3, void *a4);
typedef void *(*AddServerReactor_t)(void *session, void *reactor_sp, void *a3, void *a4);
typedef void *(*GetAccountId_t)(void *reactor, void *out_string);
static GetAccountId_t get_account_id;
static FILE *evf;  // marker events for the Lua side (live markers), one line each
static RuleRequestServer_t orig_rrs;
static AddServerReactor_t orig_asr;
static void *volatile session;
static FILE *logf;
static CRITICAL_SECTION lock;
static char players[MAX_PLAYERS][ID_LEN];  // ponytail: flat list, learned from traffic; persisted to file
static int nplayers;
static int replaying;

static int readable(const void *p, size_t n) {
    MEMORY_BASIC_INFORMATION mbi;
    if (!p || !VirtualQuery(p, &mbi, sizeof mbi)) return 0;
    if (mbi.State != MEM_COMMIT || (mbi.Protect & (PAGE_NOACCESS | PAGE_GUARD))) return 0;
    return (const char *)p + n <= (const char *)mbi.BaseAddress + mbi.RegionSize;
}

static void *deref(void *p, int off) {
    return readable((char *)p + off, 8) ? *(void **)((char *)p + off) : NULL;
}

// MSVC std::string: SSO buffer/pointer at +0, size at +0x10, capacity at +0x18.
static char *msvc_str(char *s, size_t *len) {
    if (!readable(s, 0x20)) return NULL;
    size_t size = *(size_t *)(s + 0x10), cap = *(size_t *)(s + 0x18);
    if (size > cap || cap > (1 << 26)) return NULL;
    char *d = cap > 15 ? *(char **)s : s;
    if (!readable(d, size)) return NULL;
    *len = size;
    return d;
}

static char *pb_str(void *msg, int off, size_t *len) {
    void *tp = deref(msg, off);
    return tp ? msvc_str((char *)((uintptr_t)tp & ~(uintptr_t)3), len) : NULL;
}

static int is_id(const char *p) {
    for (int i = 0; i < ID_LEN; i++)
        if (!((p[i] >= '0' && p[i] <= '9') || (p[i] >= 'A' && p[i] <= 'F'))) return 0;
    return 1;
}

static void save_players(void) {
    FILE *f = fopen(DATA_DIR "markersync_players.txt", "w");
    if (!f) return;
    for (int i = 0; i < nplayers; i++) fprintf(f, "%.32s\n", players[i]);
    fclose(f);
}

static void load_players(void) {
    FILE *f = fopen(DATA_DIR "markersync_players.txt", "r");
    char line[128];
    if (!f) return;
    while (nplayers < MAX_PLAYERS && fgets(line, sizeof line, f))
        if (strlen(line) >= ID_LEN && is_id(line)) memcpy(players[nplayers++], line, ID_LEN);
    fclose(f);
}

static void learn_player(const char *id) {
    for (int i = 0; i < nplayers; i++)
        if (!memcmp(players[i], id, ID_LEN)) return;
    if (nplayers == MAX_PLAYERS) return;
    memcpy(players[nplayers++], id, ID_LEN);
    fprintf(logf, "learned player %.32s (%d known)\n", id, nplayers);
    save_players();
}

// Reactor <-> PlayerId, learned from marker rules (the payload names the sender).
// A reactor is only used while it is still in the session's reactor list.
static struct { void *reactor; char pid[ID_LEN]; char acct[ID_LEN + 1]; } links[MAX_PLAYERS];

static void link_reactor(void *r, const char *pid) {
    int free_slot = -1;
    for (int i = 0; i < MAX_PLAYERS; i++) {
        if (links[i].reactor == r || !memcmp(links[i].pid, pid, ID_LEN)) { free_slot = i; break; }
        if (!links[i].reactor && free_slot < 0) free_slot = i;
    }
    if (free_slot < 0) free_slot = 0;  // ponytail: full table overwrites slot 0, 64 players is far beyond max
    if (links[free_slot].reactor != r) links[free_slot].acct[0] = 0;
    links[free_slot].reactor = r;
    memcpy(links[free_slot].pid, pid, ID_LEN);
}

// AccountId of a reactor, cached per link. Calls the game's own getter.
static const char *account_of(void *r) {
    for (int i = 0; i < MAX_PLAYERS; i++) {
        if (links[i].reactor != r) continue;
        if (!links[i].acct[0]) {
            // ponytail: the game allocates the id string, we never free it (once per connection)
            static char out[MAX_PLAYERS][0x80] __attribute__((aligned(16)));  // object size unknown, room to spare
            memset(out[i], 0, 0x80);
            get_account_id(r, out[i]);
            // Result is an R5 id object: vtable at +0, char data at +0x8, length at +0x18.
            char *d = *(char **)(out[i] + 0x8);
            size_t len = *(size_t *)(out[i] + 0x18);
            if (len == ID_LEN && readable(d, ID_LEN) && is_id(d)) { memcpy(links[i].acct, d, ID_LEN); links[i].acct[ID_LEN] = 0; }
            else {
                fprintf(logf, "  account lookup failed, out:");
                for (int k = 0; k < 0x20; k++) fprintf(logf, "%02x", (uint8_t)out[i][k]);
                fprintf(logf, " len=%zu\n", d ? len : (size_t)-1);
            }
        }
        return links[i].acct[0] ? links[i].acct : NULL;
    }
    return NULL;
}

// Payload after the three ids: X, Y, Z (double), Type (int32), [u32 len][name], [u32 len][namespace].
static void write_event(char op, const char *acct, const char *p, size_t plen) {
    const char *mid = p + 2 * (4 + ID_LEN) + 4;
    size_t rest = plen - 3 * (4 + ID_LEN);  // bytes after the three ids
    if (op == 'R' || rest < 32) {
        fprintf(evf, "R\t%s\t%.32s\n", acct, mid);
    } else {
        const char *q = p + 3 * (4 + ID_LEN);
        double x, y, z; int32_t type; uint32_t nl, nsl = 0;
        memcpy(&x, q, 8); memcpy(&y, q + 8, 8); memcpy(&z, q + 16, 8); memcpy(&type, q + 24, 4);
        memcpy(&nl, q + 28, 4);
        if (nl > 200 || 32 + (size_t)nl > rest) nl = 0;
        if (32 + (size_t)nl + 4 <= rest) memcpy(&nsl, q + 32 + nl, 4);
        char name[256];
        memcpy(name, q + 32, nl); name[nl] = 0;
        for (char *c = name; *c; c++) if (*c == '\t' || *c == '\n' || *c == '\r') *c = ' ';
        fprintf(evf, "%c\t%s\t%.32s\t%.1f\t%.1f\t%.1f\t%d\t%d\t%s\n", op, acct, mid, x, y, z, type, nsl > 0, name);
    }
    fflush(evf);
}

static int in_session(void *r) {
    void *s = session;
    char **it = deref(s, 0x88), **end = deref(s, 0x90);
    if (!it || !end || end < it || end - it > 2 * 256 || !readable(it, (char *)end - (char *)it)) return 0;
    for (; it < end; it += 2)  // shared_ptr = {ptr, ctrl}
        if (*it == r) return 1;
    return 0;
}

// Online reactor for a PlayerId, or NULL.
static void *find_reactor(const char *pid) {
    for (int i = 0; i < MAX_PLAYERS; i++)
        if (links[i].reactor && !memcmp(links[i].pid, pid, ID_LEN))
            return in_session(links[i].reactor) ? links[i].reactor : NULL;
    return NULL;
}

static int is_marker_rule(const char *name, size_t n) {
    static const char *rules[] = {"R5BLPlayerInWorld_AddUserMarkerRule",
                                  "R5BLPlayerInWorld_UpdateUserMarkerRule",
                                  "R5BLPlayerInWorld_RemoveUserMarkerRule"};
    for (int i = 0; i < 3; i++)
        if (n == strlen(rules[i]) && !memcmp(name, rules[i], n)) return 1;
    return 0;
}

// Replays the request on `reactor` with the payload's PlayerId swapped to `target`.
static void replay(void *reactor, void *request, void *a3, void *a4, char *reqid, char *payload, const char *target) {
    char old_req[ID_LEN], old_pid[ID_LEN];
    char *pid = payload + 4;
    memcpy(old_req, reqid, ID_LEN); memcpy(old_pid, pid, ID_LEN);
    memcpy(pid, target, ID_LEN);
    reqid[0] = reqid[0] == 'F' ? '0' : 'F';  // fresh request id
    replaying = 1;
    orig_rrs(reactor, request, a3, a4);
    replaying = 0;
    memcpy(reqid, old_req, ID_LEN); memcpy(pid, old_pid, ID_LEN);
}

static void *hook_rrs(void *reactor, void *request, void *a3, void *a4) {
    if (replaying) return orig_rrs(reactor, request, a3, a4);

    size_t nlen = 0, plen = 0, rlen = 0;
    char *name = pb_str(request, 0x18, &nlen);
    char *payload = pb_str(request, 0x20, &plen);
    char *reqid = pb_str(request, 0x10, &rlen);
    int marker = name && is_marker_rule(name, nlen) && payload && reqid && rlen == ID_LEN &&
                 plen >= 3 * (4 + ID_LEN) && *(uint32_t *)payload == ID_LEN && is_id(payload + 4);

    // Snapshot before the game runs the rule; it may consume the strings.
    char buf[4096];
    char op = marker ? name[18] : 0;  // after "R5BLPlayerInWorld_": Add / Update / Remove
    if (marker && plen <= sizeof buf) memcpy(buf, payload, plen);
    else marker = 0;

    void *ret = orig_rrs(reactor, request, a3, a4);
    if (!marker) return ret;

    EnterCriticalSection(&lock);
    fprintf(logf, "%.*s from %.32s marker %.32s\n", (int)nlen, name, buf + 4, buf + 4 + 2 * (4 + ID_LEN));
    learn_player(buf + 4);
    link_reactor(reactor, buf + 4);
    const char *acct = account_of(reactor);
    if (acct && evf) write_event(op, acct, buf, plen);

    // Re-fetch: only replay if the strings are still intact after the original call.
    size_t plen2 = 0, rlen2 = 0;
    char *payload2 = pb_str(request, 0x20, &plen2);
    char *reqid2 = pb_str(request, 0x10, &rlen2);
    if (!payload2 || plen2 != plen || memcmp(payload2, buf, plen) || !reqid2 || rlen2 != ID_LEN) {
        fprintf(logf, "  request changed by game, skip replay\n");
    } else {
        for (int i = 0; i < nplayers; i++) {
            if (!memcmp(players[i], buf + 4, ID_LEN)) continue;
            void *r = find_reactor(players[i]);
            replay(r ? r : reactor, request, a3, a4, reqid2, payload2, players[i]);
            fprintf(logf, "  replayed for %.32s via %s reactor %p\n", players[i], r ? "own" : "sender", r ? r : reactor);
        }
    }
    fflush(logf);
    LeaveCriticalSection(&lock);
    return ret;
}

static void *hook_asr(void *s, void *reactor_sp, void *a3, void *a4) {
    session = s;
    EnterCriticalSection(&lock);
    fprintf(logf, "AddServerReactor session=%p reactor=%p\n", s, deref(reactor_sp, 0));
    fflush(logf);
    LeaveCriticalSection(&lock);
    return orig_asr(s, reactor_sp, a3, a4);
}

BOOL WINAPI DllMain(HINSTANCE h, DWORD reason, LPVOID r) {
    if (reason != DLL_PROCESS_ATTACH) return TRUE;
    InitializeCriticalSection(&lock);
    logf = fopen(DATA_DIR "markersync.log", "a");
    if (!logf) return TRUE;
    load_players();
    char *base = (char *)GetModuleHandleA(NULL);
    if (memcmp(base + RVA_RULE_REQUEST_SERVER, SIG_RULE_REQUEST_SERVER, 32) ||
        memcmp(base + RVA_ADD_SERVER_REACTOR, SIG_ADD_SERVER_REACTOR, 32) ||
        memcmp(base + RVA_GET_ACCOUNT_ID, SIG_GET_ACCOUNT_ID, 32)) {
        fprintf(logf, "markersync DISABLED: game build changed, hook signatures do not match\n");
        fflush(logf);
        return TRUE;
    }
    get_account_id = (GetAccountId_t)(base + RVA_GET_ACCOUNT_ID);
    evf = fopen(DATA_DIR "markersync_events.txt", "w");
    MH_STATUS s0 = MH_Initialize();
    MH_STATUS s1 = MH_CreateHook(base + RVA_RULE_REQUEST_SERVER, (void *)hook_rrs, (void **)&orig_rrs);
    MH_STATUS s2 = MH_CreateHook(base + RVA_ADD_SERVER_REACTOR, (void *)hook_asr, (void **)&orig_asr);
    MH_STATUS s3 = MH_EnableHook(MH_ALL_HOOKS);
    fprintf(logf, "markersync loaded init=%d rrs=%d asr=%d enable=%d players=%d\n", s0, s1, s2, s3, nplayers);
    fflush(logf);
    return TRUE;
}
