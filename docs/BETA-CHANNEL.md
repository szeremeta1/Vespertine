# Beta update channel

Vespertine updates through Sparkle from one EdDSA-signed appcast, `appcast.xml` on the latest GitHub release (`SUFeedURL` in `project.yml`). Until 1.0 every release is a weekly beta on that feed's default channel. The beta channel is for builds that go to volunteer testers before a weekly release, such as release candidates and fixes that need checking on hardware Alex doesn't have (Intel Macs, multichannel DACs, receivers).

It uses Sparkle's own [channels](https://sparkle-project.org/documentation/publishing/#channels): one feed, with test builds marked `<sparkle:channel>beta</sparkle:channel>`. There is no second feed and no second signing key.

## How it works

- **Everyone else:** items with a channel are skipped. Copies that haven't opted in see exactly what they see today. Channels need Sparkle 2 in every copy that reads the feed, and every Vespertine and Nocturne build with automatic updates has shipped Sparkle 2.10 or later.
- **Testers:** `AppUpdater.allowedChannels(for:)` returns `["beta"]` when the `VespertineBetaUpdates` setting is on, so Sparkle offers items from the default channel and from `beta`, whichever is newer.
- **Ordering:** Sparkle compares `CFBundleVersion` (`CURRENT_PROJECT_VERSION`). A beta needs a higher build number than the current release, and the next release a higher one than the beta, so testers move back onto the normal releases automatically.

## Opting in and out (testers)

Needs a build that includes `allowedChannels(for:)` (the first release after this change). No settings switch exists yet; it's a hidden setting:

```bash
defaults write org.szeremeta.Vespertine VespertineBetaUpdates -bool YES   # opt in
defaults delete org.szeremeta.Vespertine VespertineBetaUpdates            # opt out
```

It takes effect at the next update check (Vespertine › Check for Updates…). Opting out doesn't downgrade: you keep the beta until a newer release arrives. For a single launch, `-VespertineBetaUpdates YES` works too.

## Publishing a beta (maintainer)

`scripts/publish.sh` publishes only to the default channel today. A beta needs three differences from a normal release. These steps are documented here but haven't been run yet:

1. **Mark the feed item.** Add `--channel beta` to the `generate_appcast` call. It only applies to items it creates, so earlier releases stay on the default channel.
2. **Don't make the beta the latest release.** Create the beta's GitHub release with `--prerelease --latest=false`. If it were Latest, the README's download link and `releases/latest` would point at it, and its `appcast.xml` would become the feed for every installed copy.
3. **Serve the new feed from the current latest release.** Installed copies read `releases/latest/download/appcast.xml`, so upload the regenerated, signed `appcast.xml` to the current Latest release with `gh release upload v<latest> appcast.xml --clobber`. While the old file is replaced, the feed is briefly missing and update checks fail quietly until the next check. Skip the Homebrew cask update: the cask follows normal releases only.

The signing doesn't change: `generate_appcast` signs the beta item and the whole feed with the same EdDSA key (keychain account `nocturne`), and `publish.sh`'s checks for the item's signature and the feed signature apply unchanged. As always, never edit `appcast.xml` by hand: with `SURequireSignedFeed` any edit breaks the signature for every installed copy.

The next normal release carries the beta item forward like any other (`publish.sh` downloads the current feed first). Copies that installed the beta then update to the release because its build number is higher.

## Not done yet

- A switch in Settings › Updates. It needs a string translated into all 44 languages.
- A `--beta` mode for `scripts/publish.sh` that does steps 1 to 3.
- A first test of the whole path: publish a beta build to the `beta` channel, confirm an opted-in copy is offered it and a normal copy isn't, then publish the next release and confirm both copies are offered it.
