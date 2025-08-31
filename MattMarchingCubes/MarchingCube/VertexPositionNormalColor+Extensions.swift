import Foundation
import RealityKit
import Metal

extension VertexPositionNormalColor {
    static var vertexAttributes: [LowLevelMesh.Attribute] = [
        .init(semantic: .position, format: .float3, offset: MemoryLayout<Self>.offset(of: \.position)!),
        .init(semantic: .normal, format: .float3, offset: MemoryLayout<Self>.offset(of: \.normal)!),
        .init(semantic: .color, format: .float3, offset: MemoryLayout<Self>.offset(of: \.color)!)
    ]
    
    static var vertexLayouts: [LowLevelMesh.Layout] = [
        .init(bufferIndex: 0, bufferStride: MemoryLayout<Self>.stride)
    ]

    static var descriptor: LowLevelMesh.Descriptor {
        var desc = LowLevelMesh.Descriptor()
        desc.vertexAttributes = VertexPositionNormalColor.vertexAttributes
        desc.vertexLayouts = VertexPositionNormalColor.vertexLayouts
        desc.indexType = .uint32
        return desc
    }
    
    @MainActor static func initializeMesh(vertexCapacity: Int,
                                          indexCapacity: Int) throws -> LowLevelMesh {
        var desc = VertexPositionNormalColor.descriptor
        desc.vertexCapacity = vertexCapacity
        desc.indexCapacity = indexCapacity

        return try LowLevelMesh(descriptor: desc)
    }
}
