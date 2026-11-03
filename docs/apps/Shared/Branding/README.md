# App artwork

Repository split (2026-11-03): see [current build paths](../../../BUILDING.md).
Product sources now live in the sibling OpenSound checkout; shared runtime,
tooling and documentation live here. Older monorepo paths below are historical.

`Logo.png` is the original artwork supplied by the user. Both Apple apps use it
as their app icon. Keep the original here rather than at the repository root.

iOS references this directory's `Assets.xcassets` from its Xcode resource phase,
with `AppIcon` selected for both build configurations. The 1024-pixel icon is a
resized copy of the original, without additional artwork or color changes.
Regenerate it after replacing `Logo.png`:

```sh
sips -z 1024 1024 src/Apps/Shared/Branding/Logo.png \
  --out src/Apps/Shared/Branding/Assets.xcassets/AppIcon.appiconset/Icon.png
```

Windows uses `AppIcon.ico` embedded into `Parvi.exe` and loaded by `parvi_windows`.
Regenerate it with Python:

```sh
python3 -c "from PIL import Image; Image.open('src/Apps/Shared/Branding/Logo.png').save('src/Apps/Shared/Branding/AppIcon.ico', format='ICO', sizes=[(16,16),(32,32),(48,48),(64,64),(128,128),(256,256)])"
```

The macOS build calls `build-mac-icon.sh` to generate the standard icon sizes
and `AppIcon.icns` under `builds/intermediates/branding/`, then copies the icon
into the app bundle. `CFBundleIconFile` selects it. Generated macOS sizes remain
outside source control. Rebuild/install the apps to update device icons.
