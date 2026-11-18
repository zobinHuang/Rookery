# branding

Rookery's earlier pixel art, generated from one set of pixel data: the old mark, the pixel crow in each state of a code agent session, and the two pixel interface icons the app still uses. The app's logo and its crows are now drawn by `BrandMark` and `CrowRig` in `Sources/RookeryCore`.

## Usage

    npm ci
    npm run build:logo

This writes the interface icons into `../Resources/Icons`, a preview of everything into `dist/preview.html`, and the old mark and crows for use elsewhere into `exports/`.
