# OpenCardboard link protocol v1

Transport: TCP. The PHONE LISTENS on port 9000; the PC connects.
- Wi-Fi: connect to the phone's IP (shown in the app's settings panel).
- USB: enable Personal Hotspot and connect the cable; the phone's address is shown
  in the panel (often 172.20.10.1). A direct usbmuxd tunnel (no hotspot) can be added
  on the PC side later without changing the app.

All values little-endian. Every message: 12-byte header + payload.

    u32 magic = 0x3143564F   (bytes 4F 56 43 31)
    u16 type
    u16 reserved = 0
    u32 payload length

Types: 1 Hello, 2 StreamConfig, 3 Pose, 4 VideoFrame, 5 Ping, 6 Pong, 7 RequestKeyframe,
       8 UiInput, 9 MenuState, 10 PcInfo

## 1 Hello (phone -> PC), sent on connect and when lens settings change  (60 bytes)
    u16 version(=1), u16 screenW, u16 screenH, u16 refreshHz
    f32 ipdMM, lensSepMM, screenToLensMM, k1, k2
    f32 leftEye  frustum: left, right, up, down  (positive tangents)
    f32 rightEye frustum: left, right, up, down

## 2 StreamConfig (PC -> phone)  (40 bytes)
    u8 codec (1=H.264, 2=HEVC), u8[3] pad, u16 width, u16 height   (full side-by-side frame)
    f32 leftEye frustum (l,r,u,d), f32 rightEye frustum (l,r,u,d)  (what the PC actually rendered)
Frame layout: left eye in the left half, right eye in the right half.

## 3 Pose (phone -> PC), every display frame (~120 Hz)  (64 bytes)
    u32 seq, u32 pad, f64 timeSeconds (phone uptime)
    f32 rotation[9]  column-major; columns = head right, up, back in a y-up, right-handed
                     space (same convention as OpenVR: -Z forward)
    f32 position[3]  zeros for now (reserved for ARKit)

## 4 VideoFrame (PC -> phone)
    u32 poseSeq, u32 flags(bit0 = keyframe)
    f32 rotation[9], f32 position[3]   the pose the frame was RENDERED with (used for timewarp)
    ...rest: one Annex-B access unit. No B-frames. Include SPS/PPS(/VPS) with every keyframe.

## 5 Ping / 6 Pong
    u64 sender timestamp; the receiver echoes the payload unchanged in a Pong.

## 7 RequestKeyframe (phone -> PC), empty payload

## 3 Pose, version 2 (76 bytes)
Same as above, then:
    f32 omega[3]     gyro rate in rad/s, in the same space as the rotation (the PC uses it for motion prediction)
`position` is now filled in when camera tracking is on (metres, same space as the rotation, origin at the last recentre).
Older receivers that read only the first 64 bytes keep working.

## 8 UiInput (PC -> phone), only while the headset menu is open (on change, and every 100 ms)  (16 bytes)
    u32 buttons      Windows XInput bits: 0x0001 up, 0x0002 down, 0x0004 left, 0x0008 right, 0x0010 start, 0x0020 back,
                     0x0040 L3, 0x0080 R3, 0x0100 LB, 0x0200 RB, 0x1000 A, 0x2000 B, 0x4000 X, 0x8000 Y
    i16 lx, ly, rx, ry   stick axes (-32768..32767)
    u8 lt, rt            triggers
    u16 reserved

## 9 MenuState (both directions)  (4 bytes)
    u8 open (0/1), u8[3] reserved
PC -> phone: open or close the headset menu (the PC sends this when the controller combination is held).
Phone -> PC: the menu is now open/closed. While it is open the PC stops sending controller clicks to SteamVR
and relays the controller to the phone as UiInput.

## 10 PcInfo (PC -> phone)
    UTF-8 text:  Name=value|Name=value|...   shown read-only in the menu's Status tab.
