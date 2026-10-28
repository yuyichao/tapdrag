// Minimal declarations for the private MultitouchSupport.framework.
// Layout matches what MiddleClick / OpenMultitouchSupport use (96 bytes/touch).
#pragma once
#include <CoreFoundation/CoreFoundation.h>

typedef struct { float x, y; } MTPoint;
typedef struct { MTPoint pos, vel; } MTVector;

typedef struct {
    int frame;
    double timestamp;
    int identifier;
    int state;          // 1..7, see MTTouchState below
    int fingerID;
    int handID;
    MTVector normalized; // pos in [0,1], origin bottom-left
    float zTotal;        // contact size
    int field9;
    float angle;
    float majorAxis;
    float minorAxis;
    MTVector absolute;
    int field14;
    int field15;
    float zDensity;
} MTTouch;

enum {
    MTTouchStateNotTracking   = 0,
    MTTouchStateStartInRange  = 1,
    MTTouchStateHoverInRange  = 2,
    MTTouchStateMakeTouch     = 3,
    MTTouchStateTouching      = 4,
    MTTouchStateBreakTouch    = 5,
    MTTouchStateLingerInRange = 6,
    MTTouchStateOutOfRange    = 7,
};

// The functions themselves (MTDeviceCreateList, MTRegisterContactFrameCallback,
// MTDeviceStart, ...) are resolved with dlsym at runtime since the SDK ships no
// stub for this private framework.
