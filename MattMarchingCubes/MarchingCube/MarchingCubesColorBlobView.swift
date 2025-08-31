import Metal
import RealityKit
import SwiftUI

struct MarchingCubesColorBlobView: View {
    @State var entity: Entity?
    @State var mesh: LowLevelMesh?
    @State var positions: [SIMD3<Float>] = []
    @State var targets: [SIMD3<Float>] = []
    @State var radii: [Float] = []
    @State var colors: [SIMD3<Float>] = []
    @State var speeds: [Float] = []
    @State var timer: Timer?
    @State var lastFrameTime = CACurrentMediaTime()
    @State var sphereCountUI: Int = 24
    @State var smoothK: Float = 0.055
    @State var targetRadius: Float = 0.0125
    @State var radiusVariance: Float = 0.3
    @State var speed: Float = 0.25
    @State var roughness: Float = 0.5
    @State var metallic: Float = 0.0
    @State var specular: Float = 0.5

    // Grid sizing
    let volumeRadius: Float = 0.175
    var cellsPerAxis: UInt32 = 40 // 80      // ... [Note] To avoid memory issues, changed to 40.
    var cells: SIMD3<UInt32> { SIMD3<UInt32>(cellsPerAxis, cellsPerAxis, cellsPerAxis) }
    var cellSize: SIMD3<Float> {
        let ratio = volumeRadius / Float(cellsPerAxis) * 2
        return SIMD3<Float>(ratio, ratio, ratio)
    }

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let computePipelineState: MTLComputePipelineState
    let vertexCountBuffer: MTLBuffer
    let spheresBuffer: MTLBuffer
    
    let maxSpheres = 64
    struct SphereData {
        var center: SIMD3<Float>
        var radius: Float
        var color: SIMD3<Float>
        var pad: Float = 0
    }
    
    enum ShaderGraphParameter: String {
        case roughness
        case metallic
        case specular
    }

    init() {
        let device = MTLCreateSystemDefaultDevice()!
        self.device = device
        self.commandQueue = device.makeCommandQueue()!
        let library = device.makeDefaultLibrary()!
        let function = library.makeFunction(name: "generateMarchingCubesColorBlobMesh")!
        self.computePipelineState = try! device.makeComputePipelineState(function: function)
        self.vertexCountBuffer = device.makeBuffer(length: MemoryLayout<UInt32>.stride, options: .storageModeShared)!
        self.spheresBuffer = device.makeBuffer(length: maxSpheres * MemoryLayout<SphereData>.stride, options: .storageModeShared)!
    }

    var body: some View {
        VStack(spacing: 40) {
            RealityView { content in
                let maxCellCount = Int(cells.x * cells.y * cells.z)
                let vertexCapacity = 15 * maxCellCount
                let indexCapacity = vertexCapacity

                let lowLevelMesh = try! VertexPositionNormalColor.initializeMesh(vertexCapacity: vertexCapacity,
                                                                            indexCapacity: indexCapacity)
                let meshResource = try! await MeshResource(from: lowLevelMesh)
                let material = try! await getMaterial()
                let entity = ModelEntity(mesh: meshResource, materials: [material])
                content.add(entity)
                self.mesh = lowLevelMesh
                self.entity = entity

                reseedSpheres(count: sphereCountUI)
                startTimer()
            }
            .onDisappear { stopTimer() }

            VStack {
                HStack {
                    Text("Spheres: \(sphereCountUI)")
                    Spacer()
                    Slider(value: Binding(get: { Double(sphereCountUI) },
                                          set: { newVal in
                                              sphereCountUI = Int(newVal)
                                              reseedSpheres(count: sphereCountUI)
                                          }),
                           in: 1...Double(maxSpheres), step: 1)
                    .frame(width: 300)
                }
                HStack {
                    Text("Target Radius: \(targetRadius, specifier: "%.4f")")
                    Spacer()
                    Slider(value: Binding(get: { Double(targetRadius) },
                                          set: { newVal in
                                              targetRadius = Float(newVal)
                                              reseedSpheres(count: sphereCountUI)
                                          }),
                           in: 0.005...0.05)
                        .frame(width: 300)
                }
                HStack {
                    Text("Radius Variance: \(radiusVariance*100, specifier: "%.1f")%")
                    Spacer()
                    Slider(value: Binding(get: { Double(radiusVariance) },
                                          set: { newVal in
                                              radiusVariance = Float(newVal)
                                              reseedSpheres(count: sphereCountUI)
                                          }),
                           in: 0.0...1.0)
                        .frame(width: 300)
                }
                HStack {
                    Text("Smooth K: \(smoothK, specifier: "%.3f")")
                    Spacer()
                    Slider(value: $smoothK, in: 0.0...0.12)
                        .frame(width: 300)
                }
                HStack {
                    Text("Speed: \(speed, specifier: "%.2f")")
                    Spacer()
                    Slider(value: $speed, in: 0.0...1.0)
                        .frame(width: 300)
                }

                HStack {
                    Text("Roughness: \(roughness, specifier: "%.2f")")
                    Spacer()
                    Slider(value: $roughness, in: 0...1.0)
                        .frame(width: 300)
                }
                .onChange(of: roughness) {
                    try? setShaderGraphParameterValue(.roughness, value: roughness)
                }
                
                HStack {
                    Text("Metallic: \(metallic, specifier: "%.2f")")
                    Spacer()
                    Slider(value: $metallic, in: 0...1)
                        .frame(width: 300)
                }
                .onChange(of: metallic) {
                    try? setShaderGraphParameterValue(.metallic, value: metallic)
                }
                
                HStack {
                    Text("Specular: \(specular, specifier: "%.2f")")
                    Spacer()
                    Slider(value: $specular, in: 0...1)
                        .frame(width: 300)
                }
                .onChange(of: specular) {
                    try? setShaderGraphParameterValue(.specular, value: specular)
                }
            }
            .frame(width: 500)
            .padding()
            .glassBackgroundEffect()
        }
    }
}

// MARK: Timer / Animation
extension MarchingCubesColorBlobView {
    func startTimer() {
        stopTimer()
        lastFrameTime = CACurrentMediaTime()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
            let now = CACurrentMediaTime()
            let deltaTime = max(0.0, now - lastFrameTime)
            lastFrameTime = now
            updateSpheres(deltaTime: Float(deltaTime))
            updateMesh()
        }
    }

    func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

// MARK: Sphere Size and Position
extension MarchingCubesColorBlobView {
    private func randomPositionWithPadding() -> SIMD3<Float> {
        let gridSizeWorldSpace = SIMD3<Float>(Float(cells.x), Float(cells.y), Float(cells.z)) * cellSize
        let minWorldSpace = -0.5 * gridSizeWorldSpace
        let maxWorldSpace = minWorldSpace + gridSizeWorldSpace
        
        // Add padding to prevent spheres from going too close to edges
        // smoothK increases size so we increase padding to compensate
        let padding: Float = volumeRadius * (0.3+smoothK*3)
        let paddedMin = minWorldSpace + padding
        let paddedMax = maxWorldSpace - padding
        
        return SIMD3<Float>(
            Float.random(in: paddedMin.x...paddedMax.x),
            Float.random(in: paddedMin.y...paddedMax.y),
            Float.random(in: paddedMin.z...paddedMax.z)
        )
    }
    
    func reseedSpheres(count: Int) {
        // Calculate min/max radius based on target and variance
        let varianceAmount = targetRadius * radiusVariance
        let minR = targetRadius - varianceAmount
        let maxR = targetRadius + varianceAmount

        positions = (0..<count).map { _ in randomPositionWithPadding() }
        targets   = (0..<count).map { _ in randomPositionWithPadding() }
        radii     = (0..<count).map { _ in Float.random(in: minR...maxR) }
        speeds    = (0..<count).map { _ in Float.random(in: 0.5...1.5) }
        colors    = (0..<count).map { i in
            let r: Float = i % 2 == 0 ? 1.0 : 0
            let g: Float = i % 2 == 0 ? 1.0 : 0
            let b: Float = i % 2 == 0 ? 1.0 : 0
            return SIMD3<Float>(r, g, b)
        }
    }

    func updateSpheres(deltaTime: Float) {
        guard positions.count == sphereCountUI else { return }

        for sphereIndex in 0..<sphereCountUI {
            let currentPosition = positions[sphereIndex]
            let targetPosition = targets[sphereIndex]
            var direction = targetPosition - currentPosition
            let distance = simd_length(direction)
            
            if distance < 1e-5 {
                targets[sphereIndex] = randomPositionWithPadding()
                continue
            }
            
            direction /= distance
            let movementStep = speed * speeds[sphereIndex] * deltaTime * volumeRadius * 1.5
            
            if movementStep >= distance {
                positions[sphereIndex] = targetPosition
                targets[sphereIndex] = randomPositionWithPadding()
            } else {
                positions[sphereIndex] = currentPosition + direction * movementStep
            }
        }

        // Write spheres to buffer
        let sphereDataPointer = spheresBuffer.contents().bindMemory(to: SphereData.self, capacity: maxSpheres)
        for sphereIndex in 0..<sphereCountUI {
            sphereDataPointer[sphereIndex] = SphereData(center: positions[sphereIndex], radius: radii[sphereIndex], color: colors[sphereIndex])
        }
    }
}

// MARK: Mesh
extension MarchingCubesColorBlobView {
    func updateMesh() {
        guard let mesh = mesh,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let computeEncoder = commandBuffer.makeComputeCommandEncoder()
        else { return }

        let gridSizeWorldSpace = SIMD3<Float>(Float(cells.x), Float(cells.y), Float(cells.z)) * cellSize
        let gridMinCornerWorldSpace = -0.5 * gridSizeWorldSpace
        let gridMaxCornerWorldSpace = gridMinCornerWorldSpace + gridSizeWorldSpace

        var params = MarchingCubesColorBlobParams(
            cells: cells,
            origin: gridMinCornerWorldSpace,
            cellSize: cellSize,
            isoLevel: 0.0,
            sphereCount: UInt32(sphereCountUI),
            smoothK: smoothK
        )

        // Reset vertex counter
        vertexCountBuffer.contents().bindMemory(to: UInt32.self, capacity: 1).pointee = 0

        // Acquire GPU-backed mesh buffers
        let vertexBuffer = mesh.replace(bufferIndex: 0, using: commandBuffer)
        let indexBuffer = mesh.replaceIndices(using: commandBuffer)

        // Encode compute
        computeEncoder.setComputePipelineState(computePipelineState)
        computeEncoder.setBuffer(vertexBuffer, offset: 0, index: 0)
        computeEncoder.setBuffer(indexBuffer, offset: 0, index: 1)
        computeEncoder.setBuffer(vertexCountBuffer, offset: 0, index: 2)
        computeEncoder.setBytes(&params, length: MemoryLayout<MarchingCubesColorBlobParams>.stride, index: 3)
        computeEncoder.setBuffer(spheresBuffer, offset: 0, index: 4)

        let threadsPerThreadgroup = MTLSize(width: 8, height: 8, depth: 4)
        let threadgroups = MTLSize(
            width: (Int(cells.x) + threadsPerThreadgroup.width - 1) / threadsPerThreadgroup.width,
            height: (Int(cells.y) + threadsPerThreadgroup.height - 1) / threadsPerThreadgroup.height,
            depth: (Int(cells.z) + threadsPerThreadgroup.depth - 1) / threadsPerThreadgroup.depth
        )
        computeEncoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerThreadgroup)
        computeEncoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let vertexCount = Int(vertexCountBuffer.contents().bindMemory(to: UInt32.self, capacity: 1).pointee)
        mesh.parts.replaceAll([
            LowLevelMesh.Part(indexCount: vertexCount,
                              topology: .triangle,
                              bounds: BoundingBox(min: gridMinCornerWorldSpace, max: gridMaxCornerWorldSpace))
        ])
    }
}

// MARK: Material
extension MarchingCubesColorBlobView {
    func getMaterial() async throws -> ShaderGraphMaterial {
        let baseURL = URL(string: "https://matt54.github.io/Resources/")!
        let fullURL = baseURL.appendingPathComponent("GeometryColorPBR.usda")
        let data = try Data(contentsOf: fullURL)
        let materialPath: String = "/Root/GeometryColorPBRMaterial"
        var material = try await ShaderGraphMaterial(named: materialPath, from: data)

        try! material.setParameter(name: ShaderGraphParameter.roughness.rawValue, value: .float(roughness))
        try! material.setParameter(name: ShaderGraphParameter.metallic.rawValue, value: .float(metallic))
        try! material.setParameter(name: ShaderGraphParameter.specular.rawValue, value: .float(specular))
        return material
    }
    
    func setShaderGraphParameterValue(_ parameter: ShaderGraphParameter, value: Float) throws {
        guard let entity = entity else { return }
        guard let modelComponent = entity.components[ModelComponent.self] else { return }
        guard var material = modelComponent.materials.first as? ShaderGraphMaterial else { return }
        try material.setParameter(name: parameter.rawValue, value: .float(value))
        entity.components[ModelComponent.self]?.materials = [material]
    }
}

#Preview { MarchingCubesColorBlobView() }
