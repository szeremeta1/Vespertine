# Security

Please report security problems privately rather than in a public issue: on the repository's **Security** tab, choose **Report a vulnerability**. Include what you found, how to reproduce it, and the Vespertine version (Vespertine › About Vespertine).

Reports are read by the maintainer and answered as soon as possible. Fixes ship as a normal update: installed copies update themselves through Sparkle, and every update is signed with the project's EdDSA key, and the app with Alexander Szeremeta's Developer ID (team `7WMQ9ZV6V8`; `codesign -dv /Applications/Vespertine.app` shows it), and notarized by Apple. Unless you'd rather not be named, the release notes credit you.

In scope: the app, its update path (the appcast and its signatures), how it mounts network shares and stores their passwords and the ListenBrainz token, the file parsers and decoders, and `vespertine-analyze`. Out of scope: GitHub Pages hosting and the third-party services the app talks to (MusicBrainz, the Cover Art Archive, ListenBrainz), which have their own reporting channels.
