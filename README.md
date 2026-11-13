# LADNIK Control Center

Internal operational console for LADNIK.

Production origin: `https://ladnik-admin.github.io`

This repository holds only the built site in `site/`. The source lives in the private LADNIK repository and is published from there by hand; `site/source.txt` records the exact private commit. Do not edit `site/` here: the next publication replaces it.

`.github/workflows/deploy-pages.yml` deploys `site/` to GitHub Pages. It builds nothing and holds no secret.

Access is enforced server-side by LADNIK Auth, the singleton platform-owner check and the exact browser-origin allowlist.
