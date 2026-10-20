/* Host side of applet, telemetry, NFC and error-display services that main reaches through IPC.
   Client-side SDK code (PlayReport encoding, keyboard presets, diag logging) runs unchanged; only the
   calls that would talk to system services are taken here. */
#include "runtime.h"
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

/* ---------- nn::oe ---------- */
static float balance[2] = {1.0f, 1.0f};
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t message_cv = PTHREAD_COND_INITIALIZER;
static uint32_t messages[32]; static unsigned head, tail;
static uint64_t start_ns;
__attribute__((constructor)) static void started(void) { start_ns = runtime_now_ns(); }

void runtime_oe_push_message(uint32_t message) {
    pthread_mutex_lock(&lock);
    if (tail - head < 32) { messages[tail++ % 32] = message; pthread_cond_broadcast(&message_cv); }
    pthread_mutex_unlock(&lock);
}
static void get_balance(float *l, float *r) { pthread_mutex_lock(&lock); if (l) *l = balance[0]; if (r) *r = balance[1]; pthread_mutex_unlock(&lock); }
static void set_balance(float l, float r) {
    if (l < 0 || l > 1 || r < 0 || r > 1) runtime_fail("volume balance out of range");
    pthread_mutex_lock(&lock); balance[0] = l; balance[1] = r; pthread_mutex_unlock(&lock);
}
static int64_t total_active_time(void) { return (int64_t)(runtime_now_ns() - start_ns); }   /* TimeSpan in ns */
/* The host never sleeps the console; the extended inactivity window has no further effect. */
static void inactivity_extended(unsigned char on) { (void)on; }
/* No system startup logo is drawn on the host, so there is nothing to dismiss. */
static void finish_startup_logo(void) { fprintf(stderr, "[totk] game finished startup logo\n"); }
/* The single native executable was launched directly; it has no predecessor
 * in an applet ExecuteProgram chain. -1 keeps the game's normal user-open path. */
static int previous_program_index(void) { return -1; }
/* A stable, nonzero resource id for this process's one application. Host input
 * and audio share that application; there is no separate system applet client. */
static uint64_t applet_resource_user_id(void) { return 1; }
static unsigned char try_pop_launch_parameter(uint64_t *size,void *buffer,uint64_t capacity) {
    (void)buffer;(void)capacity;if(size)*size=0;return 0;
}
static unsigned char try_pop(uint32_t *out) {
    pthread_mutex_lock(&lock); int ok = head != tail; if (ok && out) *out = messages[head++ % 32]; pthread_mutex_unlock(&lock); return (unsigned char)ok;
}
int runtime_core_away(void); void runtime_core_back(int *away);
static uint32_t pop(void) {
    __attribute__((cleanup(runtime_core_back))) int away = runtime_core_away();   /* blocks like a Horizon wait */
    pthread_mutex_lock(&lock); while (head == tail) pthread_cond_wait(&message_cv, &lock);
    uint32_t m = messages[head++ % 32]; pthread_mutex_unlock(&lock); return m;
}

/* ---------- nn::prepo: play reports are not transmitted (no Nintendo servers) ---------- */
static uint64_t reports;
static unsigned report_save(const void *report) { (void)report; if (!(reports++ % 100)) fprintf(stderr, "[totk] play report kept local (not transmitted), count %llu\n", (unsigned long long)reports); return 0; }
static unsigned report_save_uid(const void *report, const void *uid) { (void)uid; return report_save(report); }
static unsigned immediate_transmission(void) { return 0; }
static unsigned connection_status(void *report, const char *a, const char *b, const char *c) { (void)report; (void)a; (void)b; (void)c; return 0; }

/* ---------- nn::nfp: one virtual amiibo tag from the selected .nfc dump ----------
   The game only imports Initialize/ListDevices/GetDeviceState/Mount/GetNpadId/detection/events/
   GetTagInfo/GetModelInfo (no application-area calls), so a tag is TagInfo's UUID plus the amiibo ID the
   ModelInfo is derived from: character id, variant, type, model number and series, exactly as the service
   builds them from the 16 hex digits. The ID comes from TOTK_AMIIBO_ID (the app's catalogue); the UUID is the
   dump's NTAG215 UID. No data or keys are needed for this path. */
#define NFP_DEVICE_NOT_FOUND 0x8073u   /* nfp module 115, description 64 */
#define NFP_TAG_NOT_FOUND 0x8074u

typedef struct {
    int initialized, mounted, present, has_id, logged_tag, logged_model;
    unsigned char uuid[10];
    unsigned char uuid_len;
    char id[17];
} NfpTag;
static NfpTag tag;
static void *nfp_activate_event, *nfp_deactivate_event, *nfp_availability_event;

static uint32_t nfp_hex(const char *s, int n) {
    uint32_t v = 0;
    for (int i = 0; i < n; i++) {
        char c = (char)tolower((unsigned char)s[i]);
        v = (v << 4) | (uint32_t)(c >= '0' && c <= '9' ? c - '0' : c - 'a' + 10);
    }
    return v;
}

static void nfp_load(void) {
    static int loaded;
    if (loaded) return;
    loaded = 1;
    const char *id = getenv("TOTK_AMIIBO_ID");
    if (id && strlen(id) == 16) {
        int valid = 1;
        for (int i = 0; i < 16; i++) if (!isxdigit((unsigned char)id[i])) valid = 0;
        if (valid) { memcpy(tag.id, id, 16); tag.id[16] = 0; tag.has_id = 1; }
    }
    const char *path = getenv("TOTK_AMIIBO");
    if (path && *path) {
        FILE *f = fopen(path, "rb");
        unsigned char dump[540];
        size_t n = f ? fread(dump, 1, sizeof dump, f) : 0;
        if (f) fclose(f);
        if (n >= 8) {
            /* NTAG215 pages 0-1: UID0..2 at 0..2, BCC0 at 3, UID3..6 at 4..7. */
            tag.uuid[0] = dump[0]; tag.uuid[1] = dump[1]; tag.uuid[2] = dump[2];
            tag.uuid[3] = dump[4]; tag.uuid[4] = dump[5]; tag.uuid[5] = dump[6]; tag.uuid[6] = dump[7];
            tag.uuid_len = 7;
            tag.present = 1;
        } else {
            fprintf(stderr, "[totk] nfp: could not read %s; no amiibo is presented\n", path);
        }
    }
    if (tag.present) {
        fprintf(stderr, "[totk] nfp: virtual tag %s (uuid %02x%02x%02x%02x%02x%02x%02x, %s)\n", path,
                tag.uuid[0], tag.uuid[1], tag.uuid[2], tag.uuid[3], tag.uuid[4], tag.uuid[5], tag.uuid[6],
                tag.has_id ? tag.id : "no amiibo id");
    } else {
        fprintf(stderr, "[totk] nfp: no amiibo selected, the host has no NFC reader\n");
    }
}

static unsigned nfp_initialize(void) { nfp_load(); tag.initialized = 1; return 0; }
static unsigned nfp_finalize(void) { tag.initialized = 0; tag.mounted = 0; return 0; }
static int nfp_get_state(void) { return tag.initialized; }

static unsigned nfp_list(void *handles, int *count, int max) {
    if (!tag.present || max < 1) { if (count) *count = 0; return NFP_DEVICE_NOT_FOUND; }
    if (handles) ((uint32_t *)handles)[0] = 0;   /* one reader, handle 0 */
    if (count) *count = 1;
    return 0;
}
static int nfp_device_state(const void *h) { (void)h; return tag.present ? (tag.mounted ? 4 : 2) : 5; }
static unsigned nfp_mount(const void *h, int model, int target) {
    (void)h; (void)model; (void)target;
    if (!tag.present) return NFP_DEVICE_NOT_FOUND;
    if (!tag.mounted) {
        tag.mounted = 1;
        if (nfp_activate_event) hle_signal_system_event(nfp_activate_event);
        fprintf(stderr, "[totk] nfp: tag mounted\n");
    }
    return 0;
}
static unsigned nfp_get_npad_id(uint32_t *id, const void *h) { (void)h; if (id) *id = 0; return 0; }
static unsigned nfp_attach_availability(void *event) {
    if (!event) runtime_fail("nfp availability event");
    hle_bind_system_event(event, 0);
    nfp_availability_event = event;
    if (tag.present) hle_signal_system_event(event);
    return 0;
}
static unsigned nfp_attach_activate(void *event, const void *h) {
    (void)h;
    if (!event) runtime_fail("nfp activate event");
    hle_bind_system_event(event, 0);
    nfp_activate_event = event;
    if (tag.mounted) hle_signal_system_event(event);
    return 0;
}
static unsigned nfp_attach_deactivate(void *event, const void *h) {
    (void)h;
    if (!event) runtime_fail("nfp deactivate event");
    hle_bind_system_event(event, 0);
    nfp_deactivate_event = event;
    return 0;
}
static unsigned nfp_start_detection(const void *h) { (void)h; return tag.present ? 0 : NFP_DEVICE_NOT_FOUND; }
static unsigned nfp_stop_detection(const void *h) { (void)h; return 0; }

static unsigned nfp_get_tag_info(void *out, const void *h) {
    (void)h;
    if (!tag.present) return NFP_DEVICE_NOT_FOUND;
    unsigned char *p = out;
    memset(p, 0, 0x58);                       /* the service TagInfo: 0x58 bytes */
    memcpy(p, tag.uuid, tag.uuid_len);
    p[0x0A] = tag.uuid_len;
    *(uint32_t *)(p + 0x20) = 0xFFFFFFFFu;    /* Protocol: all */
    *(uint32_t *)(p + 0x24) = 0xFFFFFFFFu;    /* Tag type: all */
    if (!tag.logged_tag) {
        tag.logged_tag = 1;
        fprintf(stderr, "[totk] nfp: GetTagInfo, uuid %u bytes\n", tag.uuid_len);
    }
    return 0;
}

static unsigned nfp_get_model_info(void *out, const void *h) {
    (void)h;
    if (!tag.present) return NFP_DEVICE_NOT_FOUND;
    if (!tag.mounted) return NFP_TAG_NOT_FOUND;
    unsigned char *p = out;
    memset(p, 0, 0x40);                       /* ModelInfo: 0x40 bytes */
    if (tag.has_id) {
        uint32_t character = nfp_hex(tag.id, 4);
        uint32_t model = nfp_hex(tag.id + 8, 4);
        p[0] = (unsigned char)(character >> 8);              /* CharacterId, byte-reversed */
        p[1] = (unsigned char)character;
        p[2] = (unsigned char)nfp_hex(tag.id + 4, 2);        /* CharacterVariant */
        p[3] = (unsigned char)nfp_hex(tag.id + 12, 2);       /* Series */
        p[4] = (unsigned char)(model & 0xFF);                /* ModelNumber, little-endian */
        p[5] = (unsigned char)(model >> 8);
        p[6] = (unsigned char)nfp_hex(tag.id + 6, 2);        /* Type */
    }
    if (!tag.logged_model) {
        tag.logged_model = 1;
        fprintf(stderr, "[totk] nfp: GetModelInfo, character %u series %u%s\n",
                (unsigned)((p[0] << 8) | p[1]), (unsigned)p[3], tag.has_id ? "" : " (no amiibo id)");
    }
    return 0;
}

/* ---------- nn::err (nn::swkbd is in runtime/swkbd_host.c) ---------- */
static void show_error(uint32_t result) {
    fprintf(stderr, "[totk] game error dialog: %04u-%04u (result %#x)\n", 2000 + (result & 0x1ff), (result >> 9) & 0x1fff, result);
}

void *runtime_applet_override(const char *name) {
    static const struct { const char *name; void *fn; } map[] = {
        {"_ZN2nn6applet23GetPreviousProgramIndexEv", previous_program_index},
        {"_ZN2nn6applet23GetAppletResourceUserIdEv", applet_resource_user_id},
        {"_ZN2nn2am23GetAppletResourceUserIdEv", applet_resource_user_id},
        {"_ZN2nn2oe21TryPopLaunchParameterEPmPvm", try_pop_launch_parameter},
        {"_ZN2nn2oe24GetExpectedVolumeBalanceEPfS1_", get_balance}, {"_ZN2nn2oe24SetExpectedVolumeBalanceEff", set_balance},
        {"_ZN2nn2oe25GetProgramTotalActiveTimeEv", total_active_time}, {"_ZN2nn2oe38SetUserInactivityDetectionTimeExtendedEb", inactivity_extended},
        {"_ZN2nn2oe44SetUserInactivityDetectionTimeExtendedUnsafeEb", inactivity_extended},
        {"_ZN2nn2oe17FinishStartupLogoEv", finish_startup_logo}, {"_ZN2nn2oe25TryPopNotificationMessageEPj", try_pop},
        {"_ZN2nn2oe22PopNotificationMessageEv", pop},
        {"_ZN2nn5prepo10PlayReport4SaveEv", report_save}, {"_ZN2nn5prepo10PlayReport4SaveERKNS_7account3UidE", report_save_uid},
        {"_ZN2nn5prepo28RequestImmediateTransmissionEv", immediate_transmission},
        {"_ZN2nn5prepo27AddInternetConnectionStatusEPNS0_10PlayReportEPKcS4_S4_", connection_status},
        {"_ZN2nn3nfp10InitializeEv", nfp_initialize}, {"_ZN2nn3nfp8FinalizeEv", nfp_finalize}, {"_ZN2nn3nfp8GetStateEv", nfp_get_state},
        {"_ZN2nn3nfp11ListDevicesEPNS0_12DeviceHandleEPii", nfp_list},
        {"_ZN2nn3nfp29AttachAvailabilityChangeEventEPNS_2os15SystemEventTypeE", nfp_attach_availability},
        {"_ZN2nn3nfp14GetDeviceStateERKNS0_12DeviceHandleE", nfp_device_state},
        {"_ZN2nn3nfp5MountERKNS0_12DeviceHandleENS0_9ModelTypeENS0_11MountTargetE", nfp_mount},
        {"_ZN2nn3nfp9GetNpadIdEPjRKNS0_12DeviceHandleE", nfp_get_npad_id},
        {"_ZN2nn3nfp19AttachActivateEventEPNS_2os15SystemEventTypeERKNS0_12DeviceHandleE", nfp_attach_activate},
        {"_ZN2nn3nfp21AttachDeactivateEventEPNS_2os15SystemEventTypeERKNS0_12DeviceHandleE", nfp_attach_deactivate},
        {"_ZN2nn3nfp14StartDetectionERKNS0_12DeviceHandleE", nfp_start_detection}, {"_ZN2nn3nfp13StopDetectionERKNS0_12DeviceHandleE", nfp_stop_detection},
        {"_ZN2nn3nfp10GetTagInfoEPNS0_7TagInfoERKNS0_12DeviceHandleE", nfp_get_tag_info},
        {"_ZN2nn3nfp12GetModelInfoEPNS0_9ModelInfoERKNS0_12DeviceHandleE", nfp_get_model_info},
        {"_ZN2nn3err9ShowErrorENS_6ResultE", show_error},
    };
    for (size_t i = 0; i < sizeof map / sizeof *map; i++) if (!strcmp(name, map[i].name)) return map[i].fn;
    return NULL;
}
