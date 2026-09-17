# Mahfin Desktop

Desktop client for [Mahfin](https://mahfin.online), built on Qt WebEngine and
[libmpv](https://github.com/mpv-player/mpv).

The point of it is the player. In a browser, Mahfin has to work around whatever
the browser's decoders happen to support — Matroska gets demuxed in JavaScript,
HEVC is refused outright by some engines, DTS and TrueHD are never decodable, and
anything that does not fit is re-encoded by the server. mpv decodes all of it
natively, so the file is played as it is on disk and the server does no work.

Forked from [Jellyfin Desktop](https://github.com/jellyfin/jellyfin-desktop),
which is itself derived from Plex Media Player. GPL-2.0, like both.

## What changes compared to the browser

| | Browser | Mahfin Desktop |
|---|---|---|
| Matroska | demuxed in JS, one audio track at a time | native |
| HEVC / 10-bit | engine-dependent, `hev1` refused by Apple | native |
| DTS, TrueHD, PCM | always re-encoded by the server | native |
| Multi-track audio | demuxer required, 5% of the library reachable | native, instant switching |
| Subtitles | text tracks only, burned in otherwise | text, ASS/SSA and PGS/VOBSUB |
| Audio passthrough | none | AC3/DTS/E-AC3/TrueHD bitstreaming |
| Hardware decoding | whatever the engine does | VideoToolbox / D3D11 / VAAPI |

## Downloads

Built from `main` by GitHub Actions — see the Actions tab for the latest run.

macOS and Windows builds are not signed with a paid developer certificate, so
the first launch needs a right-click → Open on macOS, or "More info" → "Run
anyway" on Windows.

## Building

See [dev/](dev/) for platform-specific instructions. In short:

```sh
./dev/macos/setup.sh && ./dev/macos/build.sh    # macOS
./dev/linux/setup.sh && ./dev/linux/build.sh    # Linux
dev\windows\setup.bat && dev\windows\build.bat  # Windows
```

## Where the server comes from

The client ships pointed at `https://mahfin.online` and connects to it on
launch, so the connect screen is not normally seen. It can be changed from the
client settings modal ("Reset Saved Server"), and the client will talk to any
Jellyfin server as well.

A server qualifies if `GET <server>/System/Info/Public` answers JSON containing
a non-empty `Id`. Mahfin serves that at [`/System/Info/Public`](https://mahfin.online/System/Info/Public)
for exactly this reason.

## File locations

Data is stored per-profile in a `profiles/<profile-id>/` subdirectory. The main
configuration file is `mahfin-desktop.conf`. You can also add `mpv.conf` to
configure mpv directly.

**macOS**
- Config: `~/Library/Application Support/Mahfin Desktop/profiles/<profile-id>/`
- Cache: `~/Library/Caches/Mahfin Desktop/profiles/<profile-id>/`
- Logs: `~/Library/Logs/Mahfin Desktop/<profile-id>/`

**Windows**
- Config, cache: `%LOCALAPPDATA%\Mahfin Desktop\profiles\<profile-id>\`
- Logs: `%LOCALAPPDATA%\Mahfin Desktop\profiles\<profile-id>\logs\`

**Linux**
- Config: `~/.local/share/mahfin-desktop/profiles/<profile-id>/`
- Cache: `~/.cache/mahfin-desktop/profiles/<profile-id>/`
- Logs: `~/.local/share/mahfin-desktop/profiles/<profile-id>/logs/`
