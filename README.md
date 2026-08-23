# Nvmm

Nvmm is a Neovim GUI for Mac written in Swift with AppKit and Metal.

It comes bundled with `nvim` 0.12+ and a CLI helper called `nvmm`.

Nvmm requires macOS 15.7+ and Apple Silicon.

## Command Line Helper

The app bundle contains `nvim` and `nvmm`, a helper that opens files in a running Nvmm or launches it if needed.

To use them easily, put their folder in your `PATH`. For example, if you are using zsh, put this in your `.zprofile`:

```sh
export PATH="/Applications/Nvmm.app/Contents/bin:$PATH"
```

Alternatively, you can symlink one or both:

```sh
ln -s /Applications/Nvmm.app/Contents/bin/nvmm ~/.local/bin/nvmm
ln -s /Applications/Nvmm.app/Contents/bin/nvim ~/.local/bin/nvim
```

### Example `nvmm` usage

```text
nvmm                 # launch or activate Nvmm
nvmm a.txt           # open file
nvmm -p a.txt b.txt  # one tab per file
nvmm +42 a.txt       # put cursor at line 42
nvmm --wait a.txt    # open file and wait until its window is closed
```

Ordinary file opens reuse the best existing window. `-N`, `--wait`, or any supported Neovim option opens a new window.

Supported options are shown by `nvmm --help`.

## Build

No Apple Developer account is required. The checked-in signing configuration uses an ad-hoc signature by default.

To sign Debug with Apple Development or Release with Developer ID, copy the
local example, replace its placeholder team ID, and enable only the intended
configuration:

```sh
cp Config/Signing.local.xcconfig.example \
  Config/Signing.local.xcconfig
```

`Config/Signing.local.xcconfig` is ignored by Git. Edit that file instead of
choosing a team in Xcode's Signing & Capabilities editor; the latter writes
account-specific values into the shared project file. Keep Developer ID values
conditional on `Release` so Debug continues to use fast ad-hoc signing unless
Apple Development is explicitly enabled for it.

Download Neovim 0.12 or newer, then build the app:

```sh
Scripts/download_nvim.sh v0.12.5
xcodebuild -project Nvmm.xcodeproj -scheme Nvmm \
  -configuration Release -destination platform=macOS build
```

The app bundles Neovim's executable, libraries, and runtime. It does not use a system Neovim installation.

Run the tests with:

```sh
xcodebuild -project Nvmm.xcodeproj -scheme Nvmm \
  -destination platform=macOS test
```

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
