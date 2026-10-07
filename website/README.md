# Metope website

Astro landing page for metope.org. Self-hosted Geist, warm limestone textures, native app imagery, and hand-drawn SVG feature diagrams. The window straightens on scroll; reduced-motion preferences disable the tilt. No trackers.

## Develop and verify

```sh
npm ci
npm run dev
npm run check
npm run build
npm run preview
```

Local preview: http://127.0.0.1:4321. A project-local Node 22 runtime is included for npm scripts. The static output is `dist/`; canonical URLs and sitemap target https://metope.org. Deployment is not configured.

## Refresh the app assets

The editable icon is `../Resources/AppIcon.icon`. After building the app (and notarizing it for distribution):

```sh
npm run sync-app
npm run build
```

`sync-app` verifies the app signature, exports 256- and 1024-pixel native icon renders, and packages the download. Version changes require updating the page and script together. It does not notarize the app; use `../scripts/notarize.sh` first.

## Assets and content

- `src/assets/metope-browser.png`: rebuilt app captured with `--demo --screenshot`, using read-only sample files. This capture-only flag hides sample labels; normal sample mode remains labeled.
- `src/assets/limestone.png`: generated plain limestone texture, without the original sculpture.
- `src/components/FeatureDiagram.astro`: editable line-art SVG diagrams.
- `public/images/metope-icon*.png`: native renders of the user-edited Icon Composer document.
- Astro generates responsive WebP assets. The source screenshot is a real app capture.
- Size copy rounds the roughly 5.1 MB bundle and 3 MB ZIP. Recheck when packaging changes. No comparative speed claims are made.
- FAQ, navigation and downloads work without JavaScript. The only client script controls the scroll tilt.

The font license is in `public/FONT-LICENSE.txt`.
