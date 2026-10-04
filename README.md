# Memories

A photo and video viewer for Android TV that lets you ask questions about your photos. The answers come from [Gemma](https://ai.google.dev/gemma) running on a computer in your home, so your photos never leave the house.

## Features

- **Made for the remote.** Plug in your photo drive and the app opens by itself. Browse folders as a grid or list and pin the ones you use most.
- **Slideshows** with fade, Ken Burns or slide transitions. They resume where you left off.
- **4K, HDR and Dolby Vision video** through the TV's own decoder.
- **Date and place** on every photo, read from its GPS data.
- **Ask Gemma.** Press Down on a photo and ask about it by typing or with the remote's mic. Zoom in first to ask about one part. The answer streams in and the TV reads it aloud.

## Setting up Gemma

Gemma 4 runs through [Ollama](https://ollama.com) on any Mac or PC on the same Wi-Fi as the TV:

```sh
brew install ollama
ollama pull gemma4:e2b
OLLAMA_HOST=0.0.0.0 ollama serve   # lets the TV reach it over the network
```

Then on the TV go to **Settings > Gemma > Gemma server** and enter the computer's IP address. No API key is needed and nothing goes to the cloud.

The default model `gemma4:e2b` answers in about 3 seconds on an M3 Max. You can switch to `gemma4` for slightly better wording under **Settings > Gemma > Model**.

## Remote controls

| Button | On a photo |
|---|---|
| Left / Right | Previous or next item |
| OK | Zoom in a step (arrows move around while zoomed) |
| Up | Top bar with Ask and Slideshow |
| Down | Ask Gemma |
| Back | Zoom out, then leave |

## Building

Requires Flutter (stable) and an Android TV with developer options on.

```sh
flutter pub get
flutter run --release -d <your-tv>
```

For wireless installs turn on **Wireless debugging** on the TV and connect with `adb pair` and `adb connect`. On first launch the app asks for access to your media. To browse a USB drive it also needs **All files access**.

The Gemma code is in [`lib/services/gemma_service.dart`](lib/services/gemma_service.dart) and the Ask screen is [`lib/widgets/ask_panel.dart`](lib/widgets/ask_panel.dart).
