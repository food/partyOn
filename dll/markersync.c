// markersync: native hook DLL for the Windrose dedicated server.
// Loaded from Lua via package.loadlib(path, "*"); hooks run from DllMain.
//
// Hooks R5NetBlServerReactorV2::RuleRequestServer. When a player adds, updates
// or removes a shared map marker, the same rule request is replayed for every
// other known player by swapping the PlayerId in the payload. MarkerIds stay
// equal across players, so a removal by anyone removes the marker for everyone.
// Online players get the replay through their own reactor (so the diff reaches
// their client), offline players through the sender's reactor (save only).
//
// A marker is shared while its name starts with SHARE_PREFIX; all others stay private.
// Renaming a marker to or from the prefix turns the update into an add or a removal
// for the other players. Shared markers are kept in markersync_shared.txt.
//
// Players are also learned from the location save the server runs for everyone online
// once a minute, so they need not touch a marker first. A newly learned player gets
// all shared markers added to the save.
//
// Request layout (protobuf, ArenaStringPtr = tagged ptr to MSVC std::string):
//   +0x10 request id (32 hex)   +0x18 rule name   +0x20 payload
// Payload of PlayerInWorld rules: [u32 len][PlayerId][u32 len][IslandId][u32 len][MarkerId]...
// Session: vector<shared_ptr<Reactor>> at session+0x88 (begin) / +0x90 (end).
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "MinHook.h"

#define RVA_RULE_REQUEST_SERVER 0x4ebf9d0  // R5NetBlServerReactorV2::RuleRequestServer
#define RVA_ADD_SERVER_REACTOR 0x4e1daf0   // R5NetBlSession::AddServerReactor
#define RVA_GET_ACCOUNT_ID 0x4e43c70       // reactor -> "account-id" from the client's gRPC metadata
#define RVA_ADD_MARKER_DO 0x688b790       // R5BLPlayerInWorld_AddUserMarkerRule::Do_Impl
#define RVA_UPDATE_MARKER_DO 0x688c340    // R5BLPlayerInWorld_UpdateUserMarkerRule::Do_Impl
#define RVA_SAVE_LOCATION_DO 0x688be80    // R5BLPlayerInWorld_SaveCurrentLocationRule::Do_Impl
// First 32 bytes of each target in game build 0.10.0.9.32. Any game update moves
// code, so a mismatch means: do not hook (a wrong address would crash the server).
#define SIG_RULE_REQUEST_SERVER "\x48\x89\x5c\x24\x18\x48\x89\x74\x24\x20\x57\x41\x54\x41\x55\x41\x56\x41\x57\x48\x81\xec\x50\x0d\x00\x00\x48\x8b\x05\x4f\xa8\x93"
#define SIG_ADD_SERVER_REACTOR "\x48\x89\x5c\x24\x18\x55\x56\x57\x41\x54\x41\x55\x41\x56\x41\x57\x48\x8d\xac\x24\x50\xfa\xff\xff\x48\x81\xec\xb0\x06\x00\x00\x48"
#define SIG_GET_ACCOUNT_ID "\x40\x53\x48\x81\xec\x80\x00\x00\x00\x48\x8b\x05\xc0\x65\x9b\x0a\x48\x33\xc4\x48\x89\x44\x24\x70\x48\x8b\xda\x48\x89\x54\x24\x28"
#define SIG_ADD_MARKER_DO "\x48\x89\x5c\x24\x10\x48\x89\x74\x24\x18\x57\x48\x81\xec\xb0\x00\x00\x00\x48\x8b\x05\x97\xea\xf6\x08\x48\x33\xc4\x48\x89\x84\x24"
#define SIG_UPDATE_MARKER_DO "\x48\x89\x5c\x24\x10\x48\x89\x74\x24\x18\x57\x48\x81\xec\xb0\x00\x00\x00\x48\x8b\x05\xe7\xde\xf6\x08\x48\x33\xc4\x48\x89\x84\x24"
#define SIG_SAVE_LOCATION_DO "\x48\x89\x5c\x24\x10\x48\x89\x74\x24\x18\x57\x48\x81\xec\xb0\x00\x00\x00\x48\x8b\x05\xa7\xe3\xf6\x08\x48\x33\xc4\x48\x89\x84\x24"
#define DATA_DIR "Z:\\home\\steam\\server-files\\windrose_plus_data\\"
#define ID_LEN 32
#define MAX_PLAYERS 64
#define MAX_SHARED 4096
#define SHARE_PREFIX '!'

typedef void *(*RuleRequestServer_t)(void *reactor, void *request, void *a3, void *a4);
typedef void *(*AddServerReactor_t)(void *session, void *reactor_sp, void *a3, void *a4);
typedef void *(*GetAccountId_t)(void *reactor, void *out_string);
static GetAccountId_t get_account_id;
static FILE *evf;  // marker events for the Lua side (live markers), one line each
typedef char (*RuleDo_t)(void *rule);
static RuleDo_t orig_add_do, orig_update_do, orig_location_do;
static __thread int in_net_rule;  // set while RuleRequestServer runs on this thread
static RuleRequestServer_t orig_rrs;
static AddServerReactor_t orig_asr;
static void *volatile session;
static FILE *logf;
static CRITICAL_SECTION lock;
static char players[MAX_PLAYERS][ID_LEN];  // flat list, learned from traffic; persisted to file
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

static int send_shared_to(const char *pid);

// A player seen for the first time also gets the markers shared so far. While there is no
// connection to send them through, the player stays unknown and is learned on the next try.
static void learn_player(const char *id) {
    for (int i = 0; i < nplayers; i++)
        if (!memcmp(players[i], id, ID_LEN)) return;
    if (nplayers == MAX_PLAYERS) return;
    if (!send_shared_to(id)) {
        fprintf(logf, "no connection to send the shared markers to %.32s, learned later\n", id);
        return;
    }
    memcpy(players[nplayers++], id, ID_LEN);
    fprintf(logf, "learned player %.32s (%d known)\n", id, nplayers);
    save_players();
}

// Shared markers: MarkerId and the payload of the last add/update, persisted to
// markersync_shared.txt as "<MarkerId> <payload hex>" per line. Lists written before the
// payload was stored have the id only; those markers are not sent to new players.
static char shared[MAX_SHARED][ID_LEN];
static char *shared_payload[MAX_SHARED];
static size_t shared_plen[MAX_SHARED];
static int nshared;

// Writes the whole list; it changes when a shared marker is added, updated or unshared.
static void save_shared(void) {
    FILE *f = fopen(DATA_DIR "markersync_shared.txt", "w");
    if (!f) return;
    for (int i = 0; i < nshared; i++) {
        fprintf(f, "%.32s", shared[i]);
        if (shared_plen[i]) fputc(' ', f);
        for (size_t k = 0; k < shared_plen[i]; k++) fprintf(f, "%02x", (uint8_t)shared_payload[i][k]);
        fputc('\n', f);
    }
    fclose(f);
}

// Replaces the stored payload of entry `i`; on a failed allocation the entry keeps the id only.
static void set_payload(int i, const char *p, size_t plen) {
    free(shared_payload[i]);
    shared_payload[i] = plen ? malloc(plen) : NULL;
    shared_plen[i] = shared_payload[i] ? plen : 0;
    if (shared_plen[i]) memcpy(shared_payload[i], p, plen);
}

// Reads the list back at startup, so sharing survives a server restart.
static void load_shared(void) {
    FILE *f = fopen(DATA_DIR "markersync_shared.txt", "r");
    static char line[ID_LEN + 2 * 4096 + 8];
    char buf[4096];
    if (!f) return;
    while (nshared < MAX_SHARED && fgets(line, sizeof line, f)) {
        if (strlen(line) < ID_LEN || !is_id(line)) continue;
        size_t n = 0;
        unsigned b;
        for (char *h = line + ID_LEN + 1; line[ID_LEN] == ' ' && n < sizeof buf && sscanf(h, "%2x", &b) == 1; h += 2)
            buf[n++] = (char)b;
        memcpy(shared[nshared], line, ID_LEN);
        set_payload(nshared++, buf, n);
    }
    fclose(f);
}

// Whether the marker is currently shared.
static int is_shared(const char *mid) {
    for (int i = 0; i < nshared; i++)
        if (!memcmp(shared[i], mid, ID_LEN)) return 1;
    return 0;
}

// Adds, updates or removes the marker; `p` is the add/update payload. Returns 0 if it cannot
// be added because the list is full.
static int set_shared(const char *mid, int on, const char *p, size_t plen) {
    for (int i = 0; i < nshared; i++)
        if (!memcmp(shared[i], mid, ID_LEN)) {
            if (on) {
                set_payload(i, p, plen);
            } else {
                free(shared_payload[i]);
                memcpy(shared[i], shared[--nshared], ID_LEN);
                shared_payload[i] = shared_payload[nshared];
                shared_plen[i] = shared_plen[nshared];
                shared_payload[nshared] = NULL;
                shared_plen[nshared] = 0;
            }
            save_shared();
            return 1;
        }
    if (!on) return 1;
    if (nshared == MAX_SHARED) { fprintf(logf, "  shared list full, %.32s not shared\n", mid); return 0; }
    memcpy(shared[nshared], mid, ID_LEN);
    set_payload(nshared++, p, plen);
    save_shared();
    return 1;
}

// Whether an add/update payload names the marker with the share prefix. The name follows the
// three ids, X, Y, Z (double) and Type (int32) as [u32 len][bytes].
static int named_shared(const char *p, size_t plen) {
    size_t at = 3 * (4 + ID_LEN) + 28;
    uint32_t nl;
    if (plen < at + 5) return 0;
    memcpy(&nl, p + at, 4);
    return nl > 0 && nl <= plen - at - 4 && p[at + 4] == SHARE_PREFIX;
}

// AccountId -> the account's own PlayerId: the first PlayerId seen on one of its connections.
// A connection can also carry rules for another PlayerId (the test bot sends through a
// player's connection), so the first one is kept for good and persisted to file.
static struct { char acct[ID_LEN]; char pid[ID_LEN]; } owners[MAX_PLAYERS];
static int nowners;

// markersync_accounts.txt: one "AccountId PlayerId" line per account.
static void save_owners(void) {
    FILE *f = fopen(DATA_DIR "markersync_accounts.txt", "w");
    if (!f) return;
    for (int i = 0; i < nowners; i++) fprintf(f, "%.32s %.32s\n", owners[i].acct, owners[i].pid);
    fclose(f);
}

static void load_owners(void) {
    FILE *f = fopen(DATA_DIR "markersync_accounts.txt", "r");
    char line[128];
    if (!f) return;
    while (nowners < MAX_PLAYERS && fgets(line, sizeof line, f))
        if (strlen(line) >= 2 * ID_LEN + 1 && is_id(line) && is_id(line + ID_LEN + 1)) {
            memcpy(owners[nowners].acct, line, ID_LEN);
            memcpy(owners[nowners++].pid, line + ID_LEN + 1, ID_LEN);
        }
    fclose(f);
}

// Own PlayerId of an account; `pid` becomes it if the account is new.
static const char *owner_of(const char *acct, const char *pid) {
    for (int i = 0; i < nowners; i++)
        if (!memcmp(owners[i].acct, acct, ID_LEN)) return owners[i].pid;
    if (nowners == MAX_PLAYERS) {
        fprintf(logf, "  account table full, %.32s not stored\n", acct);
        return pid;
    }
    memcpy(owners[nowners].acct, acct, ID_LEN);
    memcpy(owners[nowners].pid, pid, ID_LEN);
    fprintf(logf, "account %.32s plays %.32s\n", acct, pid);
    save_owners();
    return owners[nowners++].pid;
}

// Reactor <-> PlayerId, learned from marker rules of the connection's own player.
// A reactor is only used while it is still in the session's reactor list.
static struct { void *reactor; char pid[ID_LEN]; } links[MAX_PLAYERS];

static void link_reactor(void *r, const char *pid) {
    int free_slot = -1;
    for (int i = 0; i < MAX_PLAYERS; i++) {
        if (links[i].reactor == r || !memcmp(links[i].pid, pid, ID_LEN)) { free_slot = i; break; }
        if (!links[i].reactor && free_slot < 0) free_slot = i;
    }
    if (free_slot < 0) free_slot = 0;  // a full table reuses slot 0; 64 players is far beyond the server limit
    links[free_slot].reactor = r;
    memcpy(links[free_slot].pid, pid, ID_LEN);
}

// AccountId of a reactor, cached per reactor; hook_asr drops the entry when a new connection
// reuses the address. Calls the game's own getter.
static struct { void *reactor; char acct[ID_LEN + 1]; } accounts[MAX_PLAYERS];

static const char *account_of(void *r) {
    int slot = -1;
    for (int i = 0; i < MAX_PLAYERS; i++) {
        if (accounts[i].reactor == r) return accounts[i].acct;
        if (!accounts[i].reactor && slot < 0) slot = i;
    }
    if (slot < 0) slot = 0;  // a full table reuses slot 0, it is looked up again when needed
    // the game allocates the id string; it is never freed (once per connection)
    static char out[MAX_PLAYERS][0x80] __attribute__((aligned(16)));  // object size unknown, room to spare
    memset(out[slot], 0, 0x80);
    get_account_id(r, out[slot]);
    // Result is an R5 id object: vtable at +0, char data at +0x8, length at +0x18.
    char *d = *(char **)(out[slot] + 0x8);
    size_t len = *(size_t *)(out[slot] + 0x18);
    if (len == ID_LEN && readable(d, ID_LEN) && is_id(d)) {
        accounts[slot].reactor = r;
        memcpy(accounts[slot].acct, d, ID_LEN);
        accounts[slot].acct[ID_LEN] = 0;
        return accounts[slot].acct;
    }
    fprintf(logf, "  account lookup failed, out:");
    for (int k = 0; k < 0x20; k++) fprintf(logf, "%02x", (uint8_t)out[slot][k]);
    fprintf(logf, " len=%zu\n", d ? len : (size_t)-1);
    return NULL;
}

// Payload after the three ids: X, Y, Z (double), Type (int32), [u32 len][name], [u32 len][namespace],
// [u32 len][MarkerClass], [u32 len][OwnerId], bSnappingAllowed (u8, the "far away" option).
// `sender` is 32 chars: the AccountId, or the PlayerId for a rule sent on someone's behalf.
static void write_event(char op, const char *sender, const char *p, size_t plen) {
    const char *mid = p + 2 * (4 + ID_LEN) + 4;
    size_t rest = plen - 3 * (4 + ID_LEN);  // bytes after the three ids
    if (op == 'R' || rest < 32) {
        fprintf(evf, "R\t%.32s\t%.32s\n", sender, mid);
    } else {
        const char *q = p + 3 * (4 + ID_LEN);
        double x, y, z; int32_t type; uint32_t nl, nsl = 0;
        memcpy(&x, q, 8); memcpy(&y, q + 8, 8); memcpy(&z, q + 16, 8); memcpy(&type, q + 24, 4);
        memcpy(&nl, q + 28, 4);
        if (nl > 200 || 32 + (size_t)nl > rest) nl = 0;
        if (32 + (size_t)nl + 4 <= rest) memcpy(&nsl, q + 32 + nl, 4);
        // Skip namespace, MarkerClass and OwnerId (each [u32 len][bytes]) to reach the flag.
        size_t at = 32 + (size_t)nl;
        for (int i = 0; i < 3 && at + 4 <= rest; i++) {
            uint32_t l;
            memcpy(&l, q + at, 4);
            at = l > 512 ? rest : at + 4 + l;
        }
        int snap = at < rest && q[at] == 1;
        char name[256];
        memcpy(name, q + 32, nl); name[nl] = 0;
        for (char *c = name; *c; c++) if (*c == '\t' || *c == '\n' || *c == '\r') *c = ' ';
        fprintf(evf, "%c\t%.32s\t%.32s\t%.1f\t%.1f\t%.1f\t%d\t%d\t%d\t%s\n", op, sender, mid, x, y, z, type, nsl > 0, snap, name);
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

static const char *marker_rules[] = {"R5BLPlayerInWorld_AddUserMarkerRule",
                                     "R5BLPlayerInWorld_UpdateUserMarkerRule",
                                     "R5BLPlayerInWorld_RemoveUserMarkerRule"};

static int is_marker_rule(const char *name, size_t n) {
    for (int i = 0; i < 3; i++)
        if (n == strlen(marker_rules[i]) && !memcmp(name, marker_rules[i], n)) return 1;
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

// MSVC std::string over a buffer we own; RuleRequestServer only reads it.
typedef struct { char *ptr; uint64_t pad; size_t size, cap; } msvc_string;

// Heap buffer with room for the terminating zero; a capacity of 16 or more avoids the SSO layout.
static void set_string(msvc_string *s, const char *data, size_t n) {
    size_t cap = n < 16 ? 16 : n;
    s->ptr = malloc(cap + 1);
    memcpy(s->ptr, data, n);
    s->ptr[n] = 0;
    s->size = n;
    s->cap = cap;
}

// Sends rule `op` (A/U/R) for `target` built from the original payload: a shared marker that
// was private before reaches the others as an add, one that turns private as a removal (the
// three ids only). The request is our own; RuleRequestServer reads only its three strings
// and no arguments after the request.
static void replay_as(void *reactor, char op, const char *reqid, const char *payload, size_t plen,
                      const char *target) {
    char buf[4096], rid[ID_LEN];
    if (op == 'R') plen = 3 * (4 + ID_LEN);
    memcpy(buf, payload, plen);
    memcpy(buf + 4, target, ID_LEN);
    memcpy(rid, reqid, ID_LEN);
    rid[0] = rid[0] == 'F' ? '0' : 'F';
    const char *rule = marker_rules[op == 'A' ? 0 : op == 'U' ? 1 : 2];
    msvc_string sid, sname, spay;
    set_string(&sid, rid, ID_LEN);
    set_string(&sname, rule, strlen(rule));
    set_string(&spay, buf, plen);
    struct { void *vtable; uintptr_t metadata; msvc_string *reqid, *name, *payload; } req =
        { NULL, 0, &sid, &sname, &spay };
    replaying = 1;
    orig_rrs(reactor, &req, NULL, NULL);
    replaying = 0;
    free(sid.ptr); free(sname.ptr); free(spay.ptr);
}

// Any connection of the session, or NULL.
static void *any_reactor(void) {
    char **it = deref(session, 0x88), **end = deref(session, 0x90);
    return it && end > it && readable(it, 8) ? *it : NULL;
}

// Adds every shared marker to the save of a player learned just now. Their own connection
// is not known yet, so this goes through any connection (save only, like replays for
// offline players); the markers show after their next login. Returns 0 without a connection.
static int send_shared_to(const char *pid) {
    void *r = any_reactor();
    int sent = 0;
    if (!r) return 0;
    in_net_rule++;
    for (int i = 0; i < nshared; i++) {
        if (!shared_plen[i]) continue;
        // a fresh request id per marker: the MarkerId with its first character changed
        replay_as(r, 'A', shared[i], shared_payload[i], shared_plen[i], pid);
        sent++;
    }
    in_net_rule--;
    fprintf(logf, "sent %d shared markers to %.32s\n", sent, pid);
    return 1;
}

static void *hook_rrs_inner(void *reactor, void *request, void *a3, void *a4);

static void *hook_rrs(void *reactor, void *request, void *a3, void *a4) {
    in_net_rule++;
    void *ret = hook_rrs_inner(reactor, request, a3, a4);
    in_net_rule--;
    return ret;
}

// Rules arriving over the network, and their replays, must always persist; only rules the
// server runs locally (CreateMarker on a player state) are candidates for the copy filter.
static void *hook_rrs_inner(void *reactor, void *request, void *a3, void *a4) {
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
    const char *mid = buf + 4 + 2 * (4 + ID_LEN);
    // What the other players get: a marker counts as shared while its name has the prefix.
    int was = is_shared(mid), now = op != 'R' && named_shared(buf, plen);
    char out = op == 'A' ? (now ? 'A' : 0)
             : op == 'U' ? (was && now ? 'U' : now ? 'A' : was ? 'R' : 0)
             : (was ? 'R' : 0);
    fprintf(logf, "%.*s from %.32s marker %.32s, others get %c\n", (int)nlen, name, buf + 4, mid, out ? out : '-');
    learn_player(buf + 4);
    const char *acct = account_of(reactor);
    // A rule for another player than the connection's own (the test bot) must not relink the
    // connection, and its live copies go to everyone, so the event names that PlayerId.
    const char *own = acct ? owner_of(acct, buf + 4) : buf + 4;
    int foreign = memcmp(own, buf + 4, ID_LEN) != 0;
    if (foreign) fprintf(logf, "  sent through the connection of %.32s\n", own);
    else link_reactor(reactor, buf + 4);
    if (!out) {
        fflush(logf);
        LeaveCriticalSection(&lock);
        return ret;
    }
    // Re-fetch: only replay if the strings are still intact after the original call. The list
    // and the live event follow only a replay that happens, so the others' saves match the list.
    size_t plen2 = 0, rlen2 = 0;
    char *payload2 = pb_str(request, 0x20, &plen2);
    char *reqid2 = pb_str(request, 0x10, &rlen2);
    if (!payload2 || plen2 != plen || memcmp(payload2, buf, plen) || !reqid2 || rlen2 != ID_LEN) {
        fprintf(logf, "  request changed by game, skip replay\n");
    } else if (set_shared(mid, now, buf, plen)) {
        if (acct && evf) write_event(out, foreign ? buf + 4 : acct, buf, plen);
        for (int i = 0; i < nplayers; i++) {
            if (!memcmp(players[i], buf + 4, ID_LEN)) continue;
            void *r = find_reactor(players[i]);
            if (out == op) replay(r ? r : reactor, request, a3, a4, reqid2, payload2, players[i]);
            else replay_as(r ? r : reactor, out, reqid2, buf, plen, players[i]);
            fprintf(logf, "  replayed for %.32s via %s reactor %p\n", players[i], r ? "own" : "sender", r ? r : reactor);
        }
    }
    fflush(logf);
    LeaveCriticalSection(&lock);
    return ret;
}

// Server-side CreateMarker runs the Add/Update user marker rule locally, which writes the
// marker into the recipient's PlayerInWorld record. Live copies made by live.lua must not be
// saved (they would come back as nameless ghosts after a relog), so both rules are skipped
// when the marker class is the Simple model, which real user markers never use.
// The rule object embeds its input model: ids at +0x160 and +0x190, the R5BLUserMarker at +0x1c0.
static int has_text(const char *d, size_t n, const char *needle) {
    size_t k = strlen(needle);
    for (size_t i = 0; i + k <= n; i++)
        if (!memcmp(d + i, needle, k)) return 1;
    return 0;
}

static int is_copy_marker(void *rule) {
    char *base = (char *)rule + 0x1c0;
    for (int off = 0; off <= 0x200; off += 8) {  // find the MarkerClass std::string
        char *s = base + off;
        if (!readable(s, 0x20)) return 0;
        size_t size = *(size_t *)(s + 0x10), cap = *(size_t *)(s + 0x18);
        if (size < 20 || size > 300 || cap < size || cap > (1 << 20)) continue;
        char *d = *(char **)s;
        if (readable(d, size) && has_text(d, size, "BP_MarkerModel_Simple")) return 1;
    }
    return 0;
}

static char hook_add_do(void *rule) {
    if (in_net_rule || !is_copy_marker(rule)) return orig_add_do(rule);
    EnterCriticalSection(&lock);
    fprintf(logf, "skipped saving a live copy (add)\n");
    fflush(logf);
    LeaveCriticalSection(&lock);
    return 1;
}

static char hook_update_do(void *rule) {
    if (in_net_rule || !is_copy_marker(rule)) return orig_update_do(rule);
    EnterCriticalSection(&lock);
    fprintf(logf, "skipped saving a live copy (update)\n");
    fflush(logf);
    LeaveCriticalSection(&lock);
    return 1;
}

// The location save runs for every online player about once a minute; its rule carries the
// PlayerId like the marker rules (R5 id at +0x160: char data at +0x168, length at +0x178).
// The id is copied before the rule runs, the markers are sent after it has finished.
static char hook_location_do(void *rule) {
    size_t len = 0;
    char *pid = msvc_str((char *)rule + 0x168, &len);
    char id[ID_LEN];
    int ok = pid && len == ID_LEN && is_id(pid);
    if (ok) memcpy(id, pid, ID_LEN);
    char ret = orig_location_do(rule);
    if (!ok) return ret;
    EnterCriticalSection(&lock);
    learn_player(id);
    fflush(logf);
    LeaveCriticalSection(&lock);
    return ret;
}

static void *hook_asr(void *s, void *reactor_sp, void *a3, void *a4) {
    session = s;
    EnterCriticalSection(&lock);
    void *r = deref(reactor_sp, 0);
    for (int i = 0; i < MAX_PLAYERS; i++) {  // a reused address is a new connection
        if (accounts[i].reactor == r) accounts[i].reactor = NULL;
        if (links[i].reactor == r) links[i].reactor = NULL;
    }
    fprintf(logf, "AddServerReactor session=%p reactor=%p\n", s, r);
    fflush(logf);
    LeaveCriticalSection(&lock);
    return orig_asr(s, reactor_sp, a3, a4);
}

// Crash diagnostics: the game's own crash handler logs no stack under Wine, so log fatal
// exceptions here (address, module, return addresses found on the stack) and let them pass on.
static char *exe_base, *dll_base;
static size_t exe_size, dll_size;
static volatile LONG crash_logs;

static size_t image_size(char *base) {
    IMAGE_NT_HEADERS *nt = (IMAGE_NT_HEADERS *)(base + ((IMAGE_DOS_HEADER *)base)->e_lfanew);
    return nt->OptionalHeader.SizeOfImage;
}

static void log_addr(const char *tag, uintptr_t a) {
    if (a >= (uintptr_t)exe_base && a < (uintptr_t)exe_base + exe_size)
        fprintf(logf, " %s exe+%llx", tag, (unsigned long long)(a - (uintptr_t)exe_base));
    else if (a >= (uintptr_t)dll_base && a < (uintptr_t)dll_base + dll_size)
        fprintf(logf, " %s markersync+%llx", tag, (unsigned long long)(a - (uintptr_t)dll_base));
}

static LONG WINAPI on_exception(EXCEPTION_POINTERS *e) {
    DWORD code = e->ExceptionRecord->ExceptionCode;
    if (code != EXCEPTION_ACCESS_VIOLATION && code != EXCEPTION_ILLEGAL_INSTRUCTION &&
        code != EXCEPTION_STACK_OVERFLOW && code != EXCEPTION_INT_DIVIDE_BY_ZERO && code != EXCEPTION_PRIV_INSTRUCTION)
        return EXCEPTION_CONTINUE_SEARCH;
    if (InterlockedIncrement(&crash_logs) > 10) return EXCEPTION_CONTINUE_SEARCH;
    CONTEXT *c = e->ContextRecord;
    fprintf(logf, "EXCEPTION %08lx tid=%lu rip=%p", code, GetCurrentThreadId(), (void *)c->Rip);
    log_addr("at", c->Rip);
    if (code == EXCEPTION_ACCESS_VIOLATION)
        fprintf(logf, " %s %p", e->ExceptionRecord->ExceptionInformation[0] ? "write" : "read",
                (void *)e->ExceptionRecord->ExceptionInformation[1]);
    fprintf(logf, "\n  stack:");
    uintptr_t *sp = (uintptr_t *)c->Rsp;
    for (int i = 0, n = 0; i < 512 && n < 24; i++) {
        if (!readable(sp + i, 8)) break;
        uintptr_t v = sp[i];
        if ((v >= (uintptr_t)exe_base && v < (uintptr_t)exe_base + exe_size) ||
            (v >= (uintptr_t)dll_base && v < (uintptr_t)dll_base + dll_size)) { log_addr("", v); n++; }
    }
    fprintf(logf, "\n");
    fflush(logf);
    return EXCEPTION_CONTINUE_SEARCH;
}

BOOL WINAPI DllMain(HINSTANCE h, DWORD reason, LPVOID r) {
    if (reason != DLL_PROCESS_ATTACH) return TRUE;
    InitializeCriticalSection(&lock);
    logf = fopen(DATA_DIR "markersync.log", "a");
    if (!logf) return TRUE;
    load_players();
    load_owners();
    load_shared();
    char *base = (char *)GetModuleHandleA(NULL);
    if (memcmp(base + RVA_RULE_REQUEST_SERVER, SIG_RULE_REQUEST_SERVER, 32) ||
        memcmp(base + RVA_ADD_SERVER_REACTOR, SIG_ADD_SERVER_REACTOR, 32) ||
        memcmp(base + RVA_GET_ACCOUNT_ID, SIG_GET_ACCOUNT_ID, 32) ||
        memcmp(base + RVA_ADD_MARKER_DO, SIG_ADD_MARKER_DO, 32) ||
        memcmp(base + RVA_UPDATE_MARKER_DO, SIG_UPDATE_MARKER_DO, 32) ||
        memcmp(base + RVA_SAVE_LOCATION_DO, SIG_SAVE_LOCATION_DO, 32)) {
        fprintf(logf, "markersync DISABLED: game build changed, hook signatures do not match\n");
        fflush(logf);
        return TRUE;
    }
    exe_base = base; exe_size = image_size(base);
    dll_base = (char *)h; dll_size = image_size((char *)h);
    AddVectoredExceptionHandler(1, on_exception);
    get_account_id = (GetAccountId_t)(base + RVA_GET_ACCOUNT_ID);
    evf = fopen(DATA_DIR "markersync_events.txt", "w");
    MH_STATUS s0 = MH_Initialize();
    MH_STATUS s1 = MH_CreateHook(base + RVA_RULE_REQUEST_SERVER, (void *)hook_rrs, (void **)&orig_rrs);
    MH_STATUS s2 = MH_CreateHook(base + RVA_ADD_SERVER_REACTOR, (void *)hook_asr, (void **)&orig_asr);
    MH_STATUS s4 = MH_CreateHook(base + RVA_ADD_MARKER_DO, (void *)hook_add_do, (void **)&orig_add_do);
    MH_STATUS s5 = MH_CreateHook(base + RVA_UPDATE_MARKER_DO, (void *)hook_update_do, (void **)&orig_update_do);
    MH_STATUS s6 = MH_CreateHook(base + RVA_SAVE_LOCATION_DO, (void *)hook_location_do, (void **)&orig_location_do);
    MH_STATUS s3 = MH_EnableHook(MH_ALL_HOOKS);
    fprintf(logf, "markersync loaded init=%d rrs=%d asr=%d add=%d update=%d location=%d enable=%d players=%d\n",
            s0, s1, s2, s4, s5, s6, s3, nplayers);
    fflush(logf);
    return TRUE;
}
