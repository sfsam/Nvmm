//
//  Nvmm
//  NeovimBundle.swift
//
//  Locates the nvim executable and runtime bundled inside the app. The build
//  copies the prebuilt distribution (from Scripts/download_nvim.sh) into the
//  bundle following Neovim's own bin/lib/share layout, mapped onto the app
//  bundle so nvim resolves its libraries (@executable_path/../lib) and runtime
//  (../share/nvim/runtime) unmodified:
//
//    Contents/MacOS/nvim          the executable (an auxiliary executable)
//    Contents/lib/*.dylib         relocated libraries
//    Contents/share/nvim/runtime  the Neovim runtime files
//

import Foundation

enum NeovimBundle {
    /// The bundled nvim executable, or nil if it is not present.
    static var executableURL: URL? {
        guard let url = Bundle.main.url(forAuxiliaryExecutable: "nvim") else {
            return nil
        }
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// The bundled Neovim runtime directory (VIMRUNTIME).
    static var runtimeURL: URL? {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/share/nvim/runtime", isDirectory: true)
    }
}
