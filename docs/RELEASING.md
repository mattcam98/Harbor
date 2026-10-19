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

1. Set `MARKETING_VERSION` (and `CURRENT_PROJECT_VERSION`) in `project.yml`,
   and commit.
2. Build the release on a Mac with Apple silicon:

       bash scripts/build-release.sh

   It builds from a clean copy of the committed source under `/tmp`, so the
   package carries the sample's generic bundle identifier rather than your
   `CodeSigning.xcconfig`, and none of your Mac's paths. It refuses to
   finish if any path under `/Users` is left in the programs.
3. Publish it, as a pre-release while Harbor is in testing:

       gh release create v<version> dist/HarborSetup-mac.zip --prerelease --title "Harbor <version>"

   `.github/workflows/pages.yml` runs when the release is published, writes
   the page's data for it, and deploys the page.
4. On a Mac that has never had Harbor Setup, open the page, paste the command
   into Terminal with an iPhone connected, and install.

To check the page locally, write its data from a local build and serve
`site/`:

    bash scripts/build-site.sh dist/HarborSetup-mac.zip owner/name https://owner.github.io/name
    python3 -m http.server --directory site

## Known limits

- Apple silicon only: the programs are built for arm64.
- Part of Harbor Setup (Unicorn, for the Mac's anisette) is built for
  macOS 26. `install.sh` warns on earlier versions and carries on.
