# Releasing Hark

Hark ships outside the App Store (it needs an event tap, paste injection and
Core Audio process taps, none of which survive the sandbox). Distribution is
a Homebrew cask in `tjameswilliams/homebrew-tap`, backed by signed and
notarized dmgs served from the website's `/downloads` prefix.

## One-time setup

1. **Notary credentials.** The sibling projects already store a notarytool
   profile for this Apple ID and team; `scripts/release.sh` uses it by
   default (`opencodego-notary`). To make a Hark-specific one:
   ```sh
   xcrun notarytool store-credentials hark-notary \
     --apple-id <your Apple ID> --team-id 7NHJT99NX8
   ```
   then run releases with `NOTARY_PROFILE=hark-notary`.

2. **Website deployed once**, so `website/infra/outputs.json` holds the
   site origin that the cask url is stamped with:
   ```sh
   website/scripts/deploy.sh
   ```

## Each release

```sh
scripts/release.sh 0.1.0               # build, sign, notarize, dmg, stamp packaging/hark.rb
website/scripts/deploy.sh              # site + dmgs -> S3/CloudFront
cp packaging/hark.rb "$(brew --repo tjameswilliams/tap)/Casks/hark.rb"
brew audit --cask --online tjameswilliams/tap/hark
(cd "$(brew --repo tjameswilliams/tap)" && git add Casks/hark.rb && git commit -m "hark 0.1.0" && git push)
```

Hash the **served** dmg, not the local one, before trusting the stamp:

```sh
curl -sL "$(node -p "require('./website/infra/outputs.json').HarkWebsite.SiteUrl")/downloads/Hark-0.1.0.dmg" | shasum -a 256
```

They should match; if they don't, the upload is what users get.

Run the audit every time. The cask pins `Hark-<version>.dmg`, which
`deploy.sh` uploads without `--delete` and therefore keeps forever; the
website's download button points at the evergreen `Hark.dmg`, which floats.
Never point the cask at the evergreen file: the pinned sha256 would break
`brew install` the moment the next release lands.

`release.sh <version> --skip-notarize` is fine for a local smoke test;
never publish an un-notarized dmg. Gatekeeper will refuse it on any Mac but
this one.

## Updates

There is no in-app updater. `brew upgrade` is the update path, so the cask
deliberately omits `auto_updates`. If Sparkle is added later, add
`auto_updates true`, a `livecheck` block against the appcast, and the
appcast upload to `deploy.sh`, following the sibling project's
`website/scripts/deploy.sh`.

## Version numbers

`CFBundleShortVersionString` is the human version (`0.1.0`), passed to
`build-app.sh` as `HARK_VERSION`. `CFBundleVersion` is a UTC datestamp
(`HARK_BUILD`), monotonic without bookkeeping. The checked-in Info.plist
keeps development values; only release builds are stamped.
