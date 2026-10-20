/* Native macOS controllers feed the same FullKey state as the keyboard. */
#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <IOKit/hid/IOHIDManager.h>
#import <IOKit/hid/IOHIDKeys.h>
#import <IOKit/hid/IOHIDUsageTables.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include "runtime.h"
#include "gamepad_layout.h"   // face buttons by position (PlayStation, Xbox) or label (Nintendo)
#include "controller_map.h"   // the player's button layout (controls.txt)

static pthread_mutex_t gamepadLock = PTHREAD_MUTEX_INITIALIZER;
static RuntimeGamepadState gamepadState;
static uint64_t pressedEdges;
static BOOL started;
static uint16_t controllerMap[CONTROLLER_BUTTONS];
static uint8_t controllerModes[CONTROLLER_BUTTONS];
static uint64_t physicalPrev;
static uint64_t tapUntil[CONTROLLER_BUTTONS];   /* ns, for tap */
static int toggleOn[CONTROLLER_BUTTONS];        /* for toggle */
static int toggleMoved[CONTROLLER_BUTTONS];     /* the stick moved since the toggle went on */
static void refresh_gamepads(void);

/* The player's button layout (controller_map.h): TOTK_CONTROLS names the file (the launcher: <data>/controls.txt and
   checks it first). No file: the default layout. */
static void load_controller_map(void) {
    controller_map_default(controllerMap, controllerModes);
    const char *path = getenv("TOTK_CONTROLS");
    FILE *f = path && *path ? fopen(path, "rb") : NULL;
    if (!f) { fprintf(stderr, "[totk-input] controller layout: default\n"); return; }
    char text[16384]; size_t n = fread(text, 1, sizeof text - 1, f); int whole = feof(f); fclose(f);
    if (!whole) runtime_fail("controller layout file too large");
    text[n] = 0;
    const char *error = NULL; int line = controller_map_parse(text, controllerMap, controllerModes, &error);
    if (line) { fprintf(stderr, "[totk-input] %s line %d: %s\n", path, line, error); runtime_fail("controller layout file"); }
    uint16_t defaults[CONTROLLER_BUTTONS]; uint8_t defaultModes[CONTROLLER_BUTTONS]; controller_map_default(defaults, defaultModes);
    int changed = 0; for (int i = 0; i < CONTROLLER_BUTTONS; i++) changed += controllerMap[i] != defaults[i];
    fprintf(stderr, "[totk-input] controller layout: %s (%d buttons changed)\n", path, changed);
}

static int32_t stick_axis(float value) {
    const float deadzone = 0.12f;
    float magnitude = fabsf(value);
    if (magnitude <= deadzone) return 0;
    if (magnitude > 1.0f) magnitude = 1.0f;
    int32_t result = (int32_t)((magnitude - deadzone) / (1.0f - deadzone) * 32767.0f);
    return value < 0 ? -result : result;
}

static int32_t stronger_axis(int32_t a, int32_t b) {
    return abs(b) > abs(a) ? b : a;
}

static int face_by_position(GCController *controller) {
    return gamepad_face_by_position(controller.productCategory.UTF8String, controller.vendorName.UTF8String);
}

/* The physical buttons held, bit i = controller_physical_names[i]; the face buttons by where they sit
   (gamepad_face_positions), so one layout file means the same buttons on every controller. */
static uint64_t gamepad_buttons(GCExtendedGamepad *pad, int by_position) {
    uint64_t buttons = gamepad_face_positions(pad.buttonA.isPressed, pad.buttonB.isPressed, pad.buttonX.isPressed, pad.buttonY.isPressed, by_position);
    if (pad.leftThumbstickButton.isPressed) buttons |= 1ULL << 4;
    if (pad.rightThumbstickButton.isPressed) buttons |= 1ULL << 5;
    if (pad.leftShoulder.isPressed) buttons |= 1ULL << 6;
    if (pad.rightShoulder.isPressed) buttons |= 1ULL << 7;
    if (pad.leftTrigger.isPressed) buttons |= 1ULL << 8;
    if (pad.rightTrigger.isPressed) buttons |= 1ULL << 9;
    if (pad.buttonMenu.isPressed) buttons |= 1ULL << 10;
    if (pad.buttonOptions.isPressed) buttons |= 1ULL << 11;
    if (pad.dpad.left.isPressed) buttons |= 1ULL << 12;
    if (pad.dpad.up.isPressed) buttons |= 1ULL << 13;
    if (pad.dpad.right.isPressed) buttons |= 1ULL << 14;
    if (pad.dpad.down.isPressed) buttons |= 1ULL << 15;
    if ([pad isKindOfClass:GCDualSenseGamepad.class] && ((GCDualSenseGamepad *)pad).touchpadButton.isPressed) buttons |= 1ULL << 16;
    if ([pad isKindOfClass:GCDualShockGamepad.class] && ((GCDualShockGamepad *)pad).touchpadButton.isPressed) buttons |= 1ULL << 16;
    return buttons;
}

/* Generic HID game pads. GameController only lists the families it knows (Xbox, PlayStation, Switch Pro, MFi), so a
   third-party pad that presents as a plain HID game pad — a PDP Rematch, an arcade stick — is invisible to it. This
   fallback reads the standard Generic Desktop game-pad usages (14 buttons, hat switch, X/Y/Z/Rz) into the same
   physical-button bits and stick values, so the same layout file and modes apply. GameController wins when both see a
   controller: only one source feeds player 1. */
typedef struct { uint32_t buttons; int hat; int32_t x, y, z, rz; int connected; } HIDPad;
static HIDPad hidPad;
static pthread_mutex_t hidLock = PTHREAD_MUTEX_INITIALIZER;
static IOHIDManagerRef hidManager;

static void hid_reset_locked(void) {
    hidPad.buttons = 0;
    hidPad.hat = -1;
    hidPad.x = hidPad.y = hidPad.z = hidPad.rz = 128;
}

/* Physical button bits (controller_map.h): HID usages follow the Switch order 1 B, 2 A, 3 Y, 4 X, then L, R, ZL, ZR,
   minus, plus, L3, R3. Positional bits, then the player's layout maps them as usual. */
static uint64_t hid_physical_locked(void) {
    uint64_t b = 0;
    uint32_t m = hidPad.buttons;
    if (m & (1u << 0)) b |= 1ULL << 0;    /* south */
    if (m & (1u << 1)) b |= 1ULL << 1;    /* east */
    if (m & (1u << 2)) b |= 1ULL << 2;    /* west */
    if (m & (1u << 3)) b |= 1ULL << 3;    /* north */
    if (m & (1u << 10)) b |= 1ULL << 4;   /* L3 */
    if (m & (1u << 11)) b |= 1ULL << 5;   /* R3 */
    if (m & (1u << 4)) b |= 1ULL << 6;    /* L */
    if (m & (1u << 5)) b |= 1ULL << 7;    /* R */
    if (m & (1u << 6)) b |= 1ULL << 8;    /* ZL */
    if (m & (1u << 7)) b |= 1ULL << 9;    /* ZR */
    if (m & (1u << 9)) b |= 1ULL << 10;   /* plus */
    if (m & (1u << 8)) b |= 1ULL << 11;   /* minus */
    int h = hidPad.hat;
    if (h == 0 || h == 1 || h == 7) b |= 1ULL << 13;   /* up */
    if (h == 2 || h == 1 || h == 3) b |= 1ULL << 14;   /* right */
    if (h == 4 || h == 3 || h == 5) b |= 1ULL << 15;   /* down */
    if (h == 6 || h == 5 || h == 7) b |= 1ULL << 12;   /* left */
    return b;
}

static void hid_input(void *context, IOReturn result, void *sender, IOHIDValueRef value) {
    (void)context; (void)result; (void)sender;
    IOHIDElementRef element = IOHIDValueGetElement(value);
    if (!element) return;
    uint32_t page = IOHIDElementGetUsagePage(element), usage = IOHIDElementGetUsage(element);
    CFIndex raw = IOHIDValueGetIntegerValue(value);
    int changed = 0;
    pthread_mutex_lock(&hidLock);
    if (page == kHIDPage_Button) {
        if (usage >= 1 && usage <= 14) {
            uint32_t bit = 1u << (usage - 1), before = hidPad.buttons;
            if (raw) hidPad.buttons |= bit; else hidPad.buttons &= ~bit;
            changed = before != hidPad.buttons;
            if (getenv("TOTK_INPUT_LOG")) fprintf(stderr, "[totk-input] HID button %u %s\n", usage, raw ? "down" : "up");
        }
    } else if (page == kHIDPage_GenericDesktop) {
        switch (usage) {
        case kHIDUsage_GD_X: hidPad.x = (int32_t)raw; changed = 1; break;
        case kHIDUsage_GD_Y: hidPad.y = (int32_t)raw; changed = 1; break;
        case kHIDUsage_GD_Z: hidPad.z = (int32_t)raw; changed = 1; break;
        case kHIDUsage_GD_Rz: hidPad.rz = (int32_t)raw; changed = 1; break;
        case kHIDUsage_GD_Hatswitch: hidPad.hat = (int)raw; changed = 1; break;
        default: break;
        }
    }
    pthread_mutex_unlock(&hidLock);
    if (changed) refresh_gamepads();
}

static void hid_named(IOHIDDeviceRef device, const char *fallback) {
    CFTypeRef name = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDProductKey));
    char text[128];
    text[0] = 0;
    if (name && CFGetTypeID(name) == CFStringGetTypeID())
        CFStringGetCString((CFStringRef)name, text, sizeof text, kCFStringEncodingUTF8);
    fprintf(stderr, "[totk-input] native HID gamepad %s: %s\n", fallback, text[0] ? text : "unknown");
}

static void hid_matched(void *context, IOReturn result, void *sender, IOHIDDeviceRef device) {
    (void)context; (void)result; (void)sender;
    IOReturn opened = IOHIDDeviceOpen(device, kIOHIDOptionsTypeNone);
    hid_named(device, "connected");
    if (opened != kIOReturnSuccess)
        fprintf(stderr, "[totk-input] HID gamepad could not be opened (%#x); Input Monitoring might be needed\n", opened);
    pthread_mutex_lock(&hidLock);
    hidPad.connected = 1;
    hid_reset_locked();
    pthread_mutex_unlock(&hidLock);
    refresh_gamepads();
}

static void hid_removed(void *context, IOReturn result, void *sender, IOHIDDeviceRef device) {
    (void)context; (void)result; (void)sender;
    hid_named(device, "disconnected");
    pthread_mutex_lock(&hidLock);
    hidPad.connected = 0;
    hid_reset_locked();
    pthread_mutex_unlock(&hidLock);
    refresh_gamepads();
}

static void hid_start(void) {
    hidManager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    if (!hidManager) return;
    NSDictionary *pads = @{(__bridge NSString *)CFSTR(kIOHIDDeviceUsagePageKey): @(kHIDPage_GenericDesktop),
                           (__bridge NSString *)CFSTR(kIOHIDDeviceUsageKey): @(kHIDUsage_GD_GamePad)};
    NSDictionary *sticks = @{(__bridge NSString *)CFSTR(kIOHIDDeviceUsagePageKey): @(kHIDPage_GenericDesktop),
                             (__bridge NSString *)CFSTR(kIOHIDDeviceUsageKey): @(kHIDUsage_GD_Joystick)};
    IOHIDManagerSetDeviceMatchingMultiple(hidManager, (__bridge CFArrayRef)@[pads, sticks]);
    IOHIDManagerRegisterDeviceMatchingCallback(hidManager, hid_matched, NULL);
    IOHIDManagerRegisterDeviceRemovalCallback(hidManager, hid_removed, NULL);
    IOHIDManagerRegisterInputValueCallback(hidManager, hid_input, NULL);
    IOHIDManagerSetDispatchQueue(hidManager, dispatch_get_main_queue());
    IOReturn opened = IOHIDManagerOpen(hidManager, kIOHIDOptionsTypeNone);
    if (opened != kIOReturnSuccess)
        fprintf(stderr, "[totk-input] HID gamepads unavailable (%#x); Input Monitoring may be needed\n", opened);
}


static void refresh_gamepads(void) {
    RuntimeGamepadState next = {0};
    uint64_t physical = 0;
    for (GCController *controller in GCController.controllers) {
        GCExtendedGamepad *pad = controller.extendedGamepad;
        if (!pad) continue;
        next.connected = 1;
        physical |= gamepad_buttons(pad, face_by_position(controller));
        next.lx = stronger_axis(next.lx, stick_axis(pad.leftThumbstick.xAxis.value));
        next.ly = stronger_axis(next.ly, stick_axis(pad.leftThumbstick.yAxis.value));
        next.rx = stronger_axis(next.rx, stick_axis(pad.rightThumbstick.xAxis.value));
        next.ry = stronger_axis(next.ry, stick_axis(pad.rightThumbstick.yAxis.value));
    }
    /* Modes work on the physical buttons, not on the mapped ones: two physical buttons may share a Switch button
       (X and L3 both running), and a mapped edge would be lost while the other one is held. */
    pthread_mutex_lock(&hidLock);
    if (!next.connected && hidPad.connected) {
        next.connected = 1;
        physical |= hid_physical_locked();
        next.lx = stronger_axis(next.lx, stick_axis((hidPad.x - 128) / 127.0f));
        next.ly = stronger_axis(next.ly, stick_axis((128 - hidPad.y) / 127.0f));
        next.rx = stronger_axis(next.rx, stick_axis((hidPad.z - 128) / 127.0f));
        next.ry = stronger_axis(next.ry, stick_axis((128 - hidPad.rz) / 127.0f));
    }
    pthread_mutex_unlock(&hidLock);
    uint64_t now = runtime_now_ns(), edges = physical & ~physicalPrev, synthetic = 0, suppressed = 0;
    int moving = next.lx || next.ly;
    physicalPrev = physical;
    for (int i = 0; i < CONTROLLER_BUTTONS; i++) {
        uint64_t bit = 1ULL << i;
        int kind = controller_mode_kind(controllerModes[i]);
        if (kind == CONTROLLER_TAP && (edges & bit)) {
            tapUntil[i] = now + 400000000ULL;
            /* Release the pulse even if the controller sends no further event. */
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(400 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{ refresh_gamepads(); });
        }
        if (kind == CONTROLLER_TOGGLE) {
            if (edges & bit) { toggleOn[i] = !toggleOn[i]; toggleMoved[i] = moving; }
            if (toggleOn[i] && moving) toggleMoved[i] = 1;
            /* A toggle ends when the stick returns to center after moving, or the controller goes away; clicking at rest
               waits for the first move, and attacking while running does not stop it. */
            if (toggleOn[i] && ((toggleMoved[i] && !moving) || !next.connected)) toggleOn[i] = 0;
        }
        if (kind == CONTROLLER_AIM && (physical & bit)) {
            /* Aim: the Switch button is held while drawing, released while the fire button is down (the shot), and its
               fire button does nothing else meanwhile. */
            uint64_t fire = 1ULL << controller_mode_fire(controllerModes[i]);
            suppressed |= fire;
            if (!(physical & fire)) synthetic |= controllerMap[i];
        }
        int active = kind == CONTROLLER_TAP ? now < tapUntil[i] : kind == CONTROLLER_TOGGLE ? toggleOn[i] : 0;
        if (active) synthetic |= controllerMap[i];
    }
    uint64_t held = physical & ~suppressed;
    for (int i = 0; i < CONTROLLER_BUTTONS; i++) if (controllerModes[i] != CONTROLLER_HOLD) held &= ~(1ULL << i);
    next.buttons |= controller_map_apply(controllerMap, held) | synthetic;
    pthread_mutex_lock(&gamepadLock);
    pressedEdges |= next.buttons & ~gamepadState.buttons;
    gamepadState = next;
    pthread_mutex_unlock(&gamepadLock);
}

static void attach_gamepad(GCController *controller) {
    GCExtendedGamepad *pad = controller.extendedGamepad;
    if (!pad) return;
    pad.valueChangedHandler = ^(GCExtendedGamepad *changed, GCControllerElement *element) {
        (void)changed; (void)element;
        refresh_gamepads();
    };
    fprintf(stderr, "[totk-input] native gamepad connected: %s (%s), face buttons by %s\n",
            (controller.vendorName ?: @"unknown").UTF8String,
            (controller.productCategory ?: @"unknown").UTF8String, face_by_position(controller) ? "position" : "label");
    runtime_feedback_attach(controller);
    refresh_gamepads();
}

void runtime_gamepad_start(void) {
    if (started) return;
    started = YES;
    load_controller_map();
    hid_start();
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserverForName:GCControllerDidConnectNotification object:nil queue:NSOperationQueue.mainQueue
                   usingBlock:^(NSNotification *notification) { attach_gamepad(notification.object); }];
    [center addObserverForName:GCControllerDidDisconnectNotification object:nil queue:NSOperationQueue.mainQueue
                   usingBlock:^(NSNotification *notification) {
                       GCController *controller = notification.object;
                       fprintf(stderr, "[totk-input] native gamepad disconnected: %s\n",
                               (controller.vendorName ?: @"unknown").UTF8String);
                       runtime_feedback_detach(controller);
                       refresh_gamepads();
                   }];
    for (GCController *controller in GCController.controllers) attach_gamepad(controller);
    [GCController startWirelessControllerDiscoveryWithCompletionHandler:nil];
}

void runtime_gamepad_clear(void) {
    runtime_feedback_quiet();
    pthread_mutex_lock(&hidLock);
    hid_reset_locked();
    pthread_mutex_unlock(&hidLock);
    physicalPrev = 0;
    memset(tapUntil, 0, sizeof tapUntil);
    memset(toggleOn, 0, sizeof toggleOn);
    memset(toggleMoved, 0, sizeof toggleMoved);
    pthread_mutex_lock(&gamepadLock);
    gamepadState = (RuntimeGamepadState){0};
    pressedEdges = 0;
    pthread_mutex_unlock(&gamepadLock);
}

/* On-screen touch controls (iPhone, ios/app/Sources/touch_controls.m) feed a second state merged with the physical
   controllers: buttons are OR-ed (a tap shorter than one game frame is latched like a controller press), each stick
   axis takes the stronger value. */
static RuntimeGamepadState touchState;
void runtime_touch_pad_set(const RuntimeGamepadState *s) {
    pthread_mutex_lock(&gamepadLock);
    pressedEdges |= s->buttons & ~touchState.buttons;
    touchState = *s;
    pthread_mutex_unlock(&gamepadLock);
}

void runtime_gamepad_read(RuntimeGamepadState *out) {
    pthread_mutex_lock(&gamepadLock);
    *out = gamepadState;
    out->buttons |= touchState.buttons | pressedEdges;
    out->lx = stronger_axis(out->lx, touchState.lx); out->ly = stronger_axis(out->ly, touchState.ly);
    out->rx = stronger_axis(out->rx, touchState.rx); out->ry = stronger_axis(out->ry, touchState.ry);
    if (touchState.connected) out->connected = 1;
    pressedEdges = 0;
    pthread_mutex_unlock(&gamepadLock);
}
