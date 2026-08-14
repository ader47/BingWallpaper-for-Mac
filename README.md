# Bing Wallpaper for Mac

<p align="center">
  <img width="400" alt="screenshot" src="https://user-images.githubusercontent.com/4823365/181782535-6235edf9-5e70-4861-96df-b4e2719482cf.png">
</p>

BingWallpaper is a menubar app for MacOS which automatically downloads the newest [bing wallpaper of the day](https://www.microsoft.com/bing/bing-wallpaper)
and sets it as wallpaper for your monitors (and spaces!). All displays are
updated by default, or you can target only the main display or a custom set of
displays in the app settings.

By default, Bing selects the wallpaper market from your network location. You
can also choose any supported Bing country/region and language market in the
app settings.

Custom image locations are persisted using a macOS security-scoped bookmark.
Downloaded images are validated before they are stored, and app updates are
accepted only when the installer matches the SHA-256 checksum published with
the GitHub release.

The menu reports wallpaper update progress, the last successful update, the
next scheduled attempt, and download errors. Failed updates use exponential
backoff and can be retried immediately from the menu.
