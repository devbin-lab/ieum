# AISO app icon

Source: https://github.com/devbin-lab/AISO/tree/main/build

Copyright 2026 devbin-lab. Licensed under Apache-2.0; the original LICENSE and
NOTICE are preserved here and included in Windows runtime bundles.

Original PNG and SVG artwork are retained in this directory. The adapted icon
in `assets/branding/app_icon.svg` removes only the two gray indicators; the white
bars, orange circle, shape, proportions, and transparent background are retained.
`scripts/generate-app-icon.cjs` (Node.js with sharp) produces its PNG and
`windows/runner/resources/app_icon.ico` for the application and portable launcher.

Upstream Git blob IDs:

- ICO: `02405aff31f3d5762c883fd51e74dad30fd51261`
- PNG: `b28b24d12d4bdda855314973e2b2fd215aca4385`
- SVG: `ca88fb708b785e4023485f7f0d69f0d355d3600c`
