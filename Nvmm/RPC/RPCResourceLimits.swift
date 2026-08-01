//
//  Nvmm
//  RPCResourceLimits.swift
//
//  Resource limits for data controlled by an RPC peer.
//

/// Hard limits applied before peer-controlled data is allocated or retained.
///
/// Tests can supply smaller values to exercise overload paths without large
/// allocations. Production defaults leave ample room for legitimate Neovim
/// traffic while making the connection's memory exposure finite.
nonisolated struct RPCResourceLimits: Sendable {
    var maximumValueBytes = 16 << 20
    var maximumStringBytes = 8 << 20
    var maximumBinaryBytes = 8 << 20
    var maximumCollectionCount = 1 << 20
    var maximumNestingDepth = 128

    var maximumInboundQueuedBytes = 4 << 20
    var inboundResumeBytes = 2 << 20
    var maximumOutboundQueuedBytes = 4 << 20

    var maximumGridWidth = Int(Int16.max)
    var maximumGridHeight = Int(Int16.max)
    var maximumCellTextBytes = 24
    var maximumReverseRequests = 8
    var maximumRetainedBells = 16
    var maximumProgressEntries = 1_024
    var maximumHighlightGroupMappings = 64
    var maximumGuifontBytes = 4_096
    var maximumLineSpacePixels = 20

    static let production = RPCResourceLimits()
}
