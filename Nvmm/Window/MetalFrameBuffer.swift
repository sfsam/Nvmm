//
//  Nvmm
//  MetalFrameBuffer.swift
//
//  A reusable Metal buffer for one in-flight frame.
//
//  The view keeps a small ring of these so a new frame can be built while
//  earlier frames are still on the GPU. Each frame's uniforms and per-instance
//  arrays are packed into a single buffer through `allocate`. A frame is locked
//  before the CPU writes it and unlocked from the command buffer's completion
//  handler, so the ring never reuses a buffer the GPU is still reading. Writes
//  and layout happen on the main actor; only `unlock` runs off it, which is why
//  the in-use flag is atomic and the type is `@unchecked Sendable`.
//

import Metal
import Synchronization

final class MetalFrameBuffer: @unchecked Sendable {
    /// A sub-range of the buffer handed out by `allocate`.
    struct Region {
        let ptr: UnsafeMutableRawPointer
        let offset: Int
    }

    private var device: MTLDevice?
    private var buffer: MTLBuffer?
    private var basePointer: UnsafeMutableRawPointer?
    private var length = 0
    private var capacity = 0
    private let inUse = Atomic<Bool>(false)

    /// Attempts to claim the buffer. Returns false if it is still in use.
    func tryLock() -> Bool {
        inUse.exchange(true, ordering: .acquiring) == false
    }

    /// Releases the buffer. Safe to call from any thread.
    func unlock() {
        inUse.store(false, ordering: .releasing)
    }

    /// Ensures the underlying buffer is on `device` and at least `size` bytes,
    /// reallocating if needed. Invalidates previously allocated regions.
    func create(device: MTLDevice, size: Int) {
        length = 0
        var size = size

        if !isSameDevice(device) {
            self.device = device
            size = max(1_048_576, Self.alignUp(size, 8))
        } else if size <= capacity {
            return
        }

        buffer = device.makeBuffer(
            length: size,
            options: [.storageModeManaged, .cpuCacheModeWriteCombined])
        basePointer = buffer?.contents()
        capacity = size
    }

    /// Allocates a 256-byte-aligned region. Assumes sufficient capacity.
    func allocate(_ size: Int) -> Region {
        let offset = length
        length = Self.alignUp(length + size, 256)
        return Region(ptr: basePointer! + offset, offset: offset)
    }

    /// The underlying Metal buffer.
    var metalBuffer: MTLBuffer? { buffer }

    /// Marks a written range so the GPU sees the managed buffer's new contents.
    func didModify(from start: Int, length: Int) {
        buffer?.didModifyRange(start..<(start + length))
    }

    private func isSameDevice(_ device: MTLDevice) -> Bool {
        guard let current = self.device else { return false }
        return ObjectIdentifier(current) == ObjectIdentifier(device)
    }

    private static func alignUp(_ value: Int, _ alignment: Int) -> Int {
        (value + alignment - 1) & ~(alignment - 1)
    }
}
