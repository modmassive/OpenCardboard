# OpenCardboard

Phone side of the iPhone -> SteamVR headset project.

## Updating the app
Upload these files to the repo (same names overwrite). You do NOT need to re-upload .github/.
Wait for the green check in Actions, download the new .ipa, install with Sideloadly
(same Apple ID, same bundle ID every time so it updates instead of adding a new app).

## Using the app
- Tap: recenter. Long-press (1 s): open/close the settings panel.
- Settings: IPD, lens separation, screen-to-lens distance, k1, k2; 3 saved presets.
  The panel also shows the phone's IP address and link status.
- With no PC connected it shows the test grid room.

## Testing the link before the SteamVR driver exists
See tools/test_sender.py and PROTOCOL.md.
