# IGDownloader (r5-model)

Floating download button for Instagram (sideloaded). Tap = save the video on screen to Photos.
Hold the button = diagnostics report (shareable).

## How it finds the video
Instagram 450 plays video with its own pipeline, so there is no `AVURLAsset` to read.
Instead the tweak reads Instagram's data model:

    visible view / view controller  ->  IGMedia  ->  [media video]  ->  allVideoURLs

No hooks, no Substrate. Plain Objective-C runtime.

## Build
Push to `main` (or Actions -> Run workflow). Download the `IGDownloader-dylib` artifact.

## Install
Add `IGDownloader.dylib` to the Instagram IPA with GBox (Add Libraries) or Sideloadly (Inject dylibs).
