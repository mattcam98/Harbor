# Publishing a release and the download page

The download page (`site/`) is a static page on GitHub Pages. It installs
Harbor the way it has to be installed the first time: from a Mac, once.

An iPhone only opens an app that is signed for it, and only a signed-in Apple
ID can make that signature, so the first install needs a computer. Harbor
Setup does it with the person's own Apple ID; there are no shared or borrowed
certificates. After that Harbor renews itself on the phone, and on iOS 27 it
can also make a new pairing record on the phone (`docs/DEVICE-TEST.md`,
Test 6), so the Mac is not needed again.

What is published:

- **Release asset `HarborSetup-mac.zip`**: the folder `Harbor Setup` with
  `install-harbor` (`scripts/setup-runner.sh`), the two programs it runs, and
  an unsigned `Harbor.ipa` with its SHA-256. Apple silicon only.
- **`site/install.sh`**: what the page's Terminal line runs,
  `/bin/bash -c "$(curl -fsSL https://<owner>.github.io/<repo>/install.sh)"`.
  It downloads the release asset, refuses it unless its SHA-256 matches the
  one written into the script, unpacks it under
  `~/Library/Application Support/Harbor Setup/<version>` and starts
  `install-harbor`. Files fetched by `curl` are not quarantined, so macOS does
  not stop the unsigned programs; that is also why there is no double-click
  download (it would need a Developer ID and notarisation).
- **`site/release.json`**: version, size and both digests, which the page
  shows.

## Before the first release

- The release and the page must be reachable without signing in.
  `mattcam98/Harbor` is private as of 19 October 2026: make it public, or set
  `HARBOR_REPO` to a public repository that holds the releases and the page.
- Settings › Pages › Build and deployment › Source: **GitHub Actions**.
  `.github/workflows/pages.yml` then publishes `site/` whenever it changes
  on `main`, after checking that `release.json` and `install.sh` name the
  same download and digest.

## Each release

1. Set `MARKETING_VERSION` in `project.yml` if it changes.
2. Build Harbor. With the iOS 27 pairing screen (still a test):

       HARBOR_SELF_PAIRING=1 bash scripts/check.sh ipa

   Without it: `bash scripts/check.sh ipa`.
3. Package Harbor Setup with that IPA, on a Mac with Apple silicon:

       bash scripts/package-setup-mac.sh dist/Harbor.ipa

4. Write the page's data:

       bash scripts/build-site.sh

   It prints the two commands that publish: `gh release create` with
   `dist/HarborSetup-mac.zip`, then the commit and push of `site/`. Run them
   in that order, so the page never points at a download that does not exist.
5. On a Mac that has never had Harbor Setup, open the page, paste the line
   into Terminal with an iPhone connected, and install.

## Known limits

- Apple silicon only: the programs are built for arm64.
- Part of Harbor Setup (Unicorn, used for the Mac's anisette) is built for
  macOS 26. `install.sh` warns on earlier macOS and carries on; that has not
  been tried.
- The page and `install.sh` have not yet been used from GitHub Pages. They
  were checked locally: the package's own digest check, both programs
  starting from an unpacked download, and the page served from `site/`.
