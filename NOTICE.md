# Third-party and reserved material

`LICENSE` (MIT) covers the source code in this repository. It does not cover
everything shipped alongside it, so the exceptions are listed here rather than
left to be assumed.

## Icons

`nodeloc/Assets.xcassets` contains icon artwork from two open sets, redrawn as
image assets:

| Set | Assets | Upstream licence |
|---|---|---|
| Font Awesome Free | 59 × `Fa*.imageset` | Icons: CC BY 4.0 — attribution required |
| Lucide | 25 × `Lucide*.imageset` | ISC |

Both permit commercial use and redistribution. Font Awesome's icon licence
requires attribution, which is what this section provides; if you strip these
assets from a fork, the requirement goes with them.

## Brand marks

Not licensed for reuse, MIT notwithstanding — a licence on source code cannot
grant rights to someone else's trade marks:

- `NodelocWordmark`, `AppIcon`, and the NODELOC name — Nodeloc LLC
- `SocialGitHub`, `SocialGoogle`, `SocialTelegram`, and the Apple logo used by
  the sign-in button — the respective owners, used to identify their sign-in
  services as their brand guidelines require

A fork intended for another Discourse site should replace all of these.

## Screenshots and design material

- `Screenshots/` are captures of the live nodeloc.com forum. The posts,
  usernames and avatars in them belong to those users.
- `design_import/` holds the original design brief for the app. Check its
  provenance before reusing it; it was not produced for redistribution.

## Not included

`Secrets.plist` is deliberately absent and gitignored. The app builds and runs
without it; the GIF picker is disabled unless you supply your own Klipy API
key. See `DiscourseConfig.klipyAPIKey`.
