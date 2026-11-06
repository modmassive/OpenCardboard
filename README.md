# OpenCardboard

Phone side of the iPhone -> SteamVR headset project.

## Using the app
- Tap: recenter.
- Double-tap: show/hide the big status display (centered in each eye, readable in the headset).
  It also appears by itself for a few seconds at launch and whenever the PC connects or disconnects.
- Long-press (1 s): open/close the settings panel (lens settings, 3 presets, status).
- With no PC connected it shows the test grid room.

## Testing without the SteamVR driver
See tools/test_sender.py and PROTOCOL.md. Over USB: turn on Personal Hotspot ("Allow Others to Join"),
plug in the cable, and connect to the phone's address shown on the status display (often 172.20.10.1).
