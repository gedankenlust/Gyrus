# Gyrus Saver in Safari, on this Mac

This build is for the Mac where Gyrus is developed. It is ad-hoc signed and not
notarized. It does not need an Apple Developer membership. It is not the
extension other people download from GitHub.

Safari only loads it after one local switch:

1. Safari → Settings → Advanced → show features for web developers.
2. Develop menu → Allow Unsigned Extensions.

Then run:

```sh
./extension/build_safari_local.sh
```

The script converts `extension/` into a small Mac app, signs it to run locally,
and copies it to `/Applications/GyrusSaver.app`. Open that app once. Safari
asks to enable the extension. After that, the toolbar button saves the active
tab the same way as in Chrome, Brave, Arc, or Edge.

Safari assigns its own extension id (`safari-web-extension://…`). The local
backend accepts that scheme for pairing and for saving a bookmark, and still
refuses backup, notes, and AI from it. No extra account setting is required.
