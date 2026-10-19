# Publishing a release and the download page

The download page (`site/`) is a static page on GitHub Pages. It installs
Harbor the only way the first install can work: from a Mac, once, signed
with the person's own Apple ID. There are no shared certificates.

Everything here is relative to the repository it runs in, so a fork
publishes its own releases and page with no changes.

What is published:

- **Release asset `HarborSetup-mac.zip`**: the folder `Harbor Setup` with
  `install-harbor` (`scripts/setup-runner.sh`), the two programs it runs, and
  an unsigned `Harbor.ipa` with its SHA-256. Apple silicon only.
- **The page**, with `install.sh` and `release.json`. The Pages workflow
  writes both from the latest release with `scripts/build-site.sh`; they are
  not committed. `install.sh` downloads the release asset, refuses it unless
  its SHA-256 matches, unpacks it under
  `~/Library/Application Support/Harbor Setup/<version>` and starts
  `install-harbor`. Files fetched by `curl` are not quarantined, so macOS
  runs the unsigned programs; a double-click download would need a
  Developer ID and notarisation.

## Once

- The repository and its releases must be public for the page's Terminal
  command to download them.
- Settings › Pages › Build and deployment › Source: **GitHub Actions**.

## Each release

1. Set `MARKETING_VERSION` in `project.yml` if it changes.
2. Build Harbor with the default bundle identifier, or your own, in
   `CodeSigning.xcconfig`:

       bash scripts/check.sh ipa

3. Package Harbor Setup with it, on a Mac with Apple silicon:

       bash scripts/package-setup-mac.sh dist/Harbor.ipa

4. Publish the release:

       gh release create v<version> dist/HarborSetup-mac.zip --title "Harbor <version>"

   `.github/workflows/pages.yml` runs when the release is published, writes
   the page's data for it, and deploys the page.
5. On a Mac that has never had Harbor Setup, open the page, paste the command
   into Terminal with an iPhone connected, and install.

To check the page locally, write its data from a local build and serve
`site/`:

    bash scripts/build-site.sh dist/HarborSetup-mac.zip owner/name https://owner.github.io/name
    python3 -m http.server --directory site

## Known limits

- Apple silicon only: the programs are built for arm64.
- Part of Harbor Setup (Unicorn, for the Mac's anisette) is built for
  macOS 26. `install.sh` warns on earlier versions and carries on.
