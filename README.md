# Nvmm

Nvmm is a sweet [Neovim](https://github.com/neovim/neovim) GUI for Mac with GPU text rendering and native Mac look and feel.

It comes bundled with `nvim` and a CLI helper called `nvmm`.

Nvmm runs on macOS 15.7+ and Apple Silicon.

<img src="https://mowglii.com/nvmm/nvmmbanner2@2x.png" width="550" alt="Nvmm with vim-buftabline">
 
<em>
Nvmm shown with <a href="https://github.com/ap/vim-buftabline">vim-buftabline</a>, a plugin that makes Neovim's tabs make sense.
<br>
It works well with Nvmm's option to prefer buffers over tabs.
</em>

## Installation

Pre-built releases are published on the [GitHub Releases page](https://github.com/sfsam/nvmm/releases).

## Documentation

See [Nvmm Documentation](https://mowglii.com/nvmm/nvmm.html).

## Build

By default, the app gets an ad-hoc signature. No Apple Developer account is required.

First, download Neovim 0.12 or newer. The build copies it into the app. Then build the app:

```sh
Scripts/download_nvim.sh v0.12.6
xcodebuild -configuration Release
```

The app is built at:

```text
build/Release/Nvmm.app
```

The app uses its bundled Neovim unless you choose another one in Settings. See [Choosing a Neovim](https://mowglii.com/nvmm/nvmm.html#neovim).

Run the tests with:

```sh
xcodebuild -project Nvmm.xcodeproj -scheme Nvmm \
  -destination platform=macOS test
```

### Signing with Your Team

To sign with your own Apple Developer team, copy the example signing file:

```sh
cp Config/Signing.local.xcconfig.example \
  Config/Signing.local.xcconfig
```

Then edit `Config/Signing.local.xcconfig` and replace `XXXXXXXXXX` with your team ID. As provided, it signs Debug with Apple Development. To sign Release with Developer ID, uncomment its Release lines. Keep each setting's `[config=...]` part so it only affects that configuration. Any configuration you leave out keeps the ad-hoc signature.

Git ignores this file. Set up signing there, not in Xcode's Signing & Capabilities editor, because Xcode saves those choices in the shared project file.

## Acknowledgements

Nvmm is an experiment in coding with LLM agents. It was made with lots of help and inspiration, most especially from
[Claude](https://claude.com),
[Codex](https://chatgpt.com),
[Ghostty](https://ghostty.org),
[MacVim](https://macvim.org),
[Neovide](https://neovide.dev),
[Neovim for macOS](https://github.com/JaySandhu/neovim-mac),
[VimR](https://github.com/qvacua/vimr) and, of course,
[The Beatles](https://www.thebeatles.com).

## License

Nvmm is available under the MIT License. See [LICENSE.md](LICENSE.md).
