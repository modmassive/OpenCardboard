# OpenCardboard SteamVR driver (stage 1: head tracking)

Built by GitHub Actions (see .github/workflows/driver.yml). The artifact contains a folder
`opencardboard` with: driver.vrdrivermanifest, resources/settings/default.vrsettings,
bin/win64/driver_opencardboard.dll.

Settings live in opencardboard/resources/settings/default.vrsettings (close SteamVR before editing):
phoneAddress (172.20.10.1 = USB hotspot), phonePort, window and render sizes, ipd, headHeight, fovTan.
