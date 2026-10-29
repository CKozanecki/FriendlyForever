# Art

The Friendly Forever logo, as uploaded to the CurseForge project page.

- `friendly-forever-logo.svg`: the source. Edit this, then re-render.
- `friendly-forever-logo.png`: 512×512 render, with a transparent background.
- `friendly-forever-icon.svg`: the in-game icon's source (#65). A small-size
  variant of the logo: the heart and the large sparkle cropped to fill a navy
  disc, with no outer ring, since the minimap button draws its own.

These files aren't packaged into the addon. The icon ships as `Media/Icon.tga`
(64×64, 32-bit with alpha), which `node scripts/render-icon.js` renders from
the icon's SVG with the pre-installed Chromium through Playwright. Commit the
TGA with the SVG.

To re-render the PNG, use any SVG renderer at 512×512, for example the
pre-installed Chromium through Playwright.
