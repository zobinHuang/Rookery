# branding

Rookery's pixel art, generated from one set of pixel data: the mark (a murder of crows in their nest, with the name), the crow in each state of a code agent session, and the app's interface icons. Every frame is a grid of palette keys, so the edges stay sharp at any whole scale.

## Usage

    npm ci
    npm run build:logo

This writes the app's sidebar logo, crows and icons into `../Resources`, the README's logo into `../docs/images`, a preview of everything into `dist/preview.html`, and the logo for use elsewhere into `exports/`: each lockup and each crow as SVG, PNG and a looping GIF.
