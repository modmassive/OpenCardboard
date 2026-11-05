# OpenCardboard – step 1: head tracking + Cardboard lens view

1. Push the contents of this folder to the ROOT of a GitHub repo
   (project.yml must be at the top level, plus .github/ and Sources/).
2. Actions tab -> "Build IPA" runs automatically -> download the
   `OpenCardboard-ipa` artifact -> unzip to get OpenCardboard.ipa.
3. Open the .ipa in Sideloadly, sign with your Apple ID, install.
   Settings > General > VPN & Device Management: trust your profile.
4. Run it in landscape (phone top pointing left), put it in the viewer.
   Tap the screen to recenter. The red pillar is "forward".

## Tuning (Sources/Renderer.swift, LensParams)
k1/k2, screenToLensMM, lensSeparationMM, ipdMM. Values are approximate.

## If head movement is backwards
Set `useTranspose = false` in HeadTracker.swift.
