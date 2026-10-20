//
//  MetalRenderer.swift
//  NFSCarbon
//
//  Native Apple Metal pipeline renderer implementing MTKViewDelegate.
//  Drives custom MSL shader pipeline, widescreen aspect-ratio scaling
//  (pillarbox vs native widescreen 19.5:9), and triple-buffered frame synchronization.
//

import Metal
import MetalKit
import QuartzCore
import simd

public enum AspectRatioMode: Int {
    case pillarbox = 0   // Original 16:9 / 4:3 with pillarbox bars
    case widescreen = 1  // Fullscreen 19.5:9 wide stretch / crop
}

public final class MetalRenderer: NSObject, MTKViewDelegate {

    public let device: MTLDevice
    public private(set) var commandQueue: MTLCommandQueue
    private var pipelineState: MTLRenderPipelineState?
    private var samplerState: MTLSamplerState?
    private var vertexBuffer: MTLBuffer?

    // Triple buffering synchronization
    private let inflightSemaphore = DispatchSemaphore(value: 3)
    private var bufferIndex: Int = 0

    public var aspectRatioMode: AspectRatioMode = .pillarbox {
        didSet {
            updateQuadVertices()
        }
    }

    private var viewSize: CGSize = .zero
    private var renderTargetSize: CGSize = CGSize(width: 1920, height: 1080)

    // Fallback loading texture
    private var placeholderTexture: MTLTexture?

    // MSL Shader Source
    private let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexInput {
        float2 position  [[attribute(0)]];
        float2 texCoord  [[attribute(1)]];
    };

    struct RasterizerData {
        float4 position [[position]];
        float2 texCoord;
    };

    vertex RasterizerData quadVertexShader(
        uint vertexID [[vertex_id]],
        constant VertexInput* vertices [[buffer(0)]]
    ) {
        RasterizerData out;
        out.position = float4(vertices[vertexID].position, 0.0, 1.0);
        out.texCoord = vertices[vertexID].texCoord;
        return out;
    }

    fragment float4 quadFragmentShader(
        RasterizerData in [[stage_in]],
        texture2d<float, access::sample> colorTexture [[texture(0)]],
        sampler textureSampler [[sampler(0)]]
    ) {
        // High quality bilinear sample
        float4 color = colorTexture.sample(textureSampler, in.texCoord);
        return color;
    }
    """

    public init?(metalView: MTKView) {
        guard let defaultDevice = MTLCreateSystemDefaultDevice(),
              let queue = defaultDevice.makeCommandQueue() else {
            NFSCLogger.shared.fatal("METAL", "Failed to create default MTLDevice or MTLCommandQueue.")
            return nil
        }
        self.device = defaultDevice
        self.commandQueue = queue
        super.init()

        metalView.device = defaultDevice
        metalView.delegate = self
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.clearColor = MTLClearColor(red: 0.02, green: 0.02, blue: 0.03, alpha: 1.0)
        metalView.framebufferOnly = true
        metalView.preferredFramesPerSecond = 120

        setupPipeline()
        setupSampler()
        setupPlaceholderTexture()
        updateQuadVertices()

        NFSCLogger.shared.info("METAL", "MetalRenderer initialized successfully. Pipeline ready for 60/120Hz display pacing.")
    }

    // MARK: - Pipeline & State Setup

    private func setupPipeline() {
        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            guard let vertexFunction = library.makeFunction(name: "quadVertexShader"),
                  let fragmentFunction = library.makeFunction(name: "quadFragmentShader") else {
                NFSCLogger.shared.fatal("METAL", "Shader functions could not be extracted from MSL source.")
                return
            }

            let pipelineDescriptor = MTLRenderPipelineDescriptor()
            pipelineDescriptor.label = "NFSCarbonQuadPipeline"
            pipelineDescriptor.vertexFunction = vertexFunction
            pipelineDescriptor.fragmentFunction = fragmentFunction
            pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

            // Alpha blending (pre-multiplied / standard alpha)
            pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
            pipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
            pipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
            pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
            pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

            self.pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            NFSCLogger.shared.fatal("METAL", "Failed to compile Metal pipeline state: \(error.localizedDescription)")
        }
    }

    private func setupSampler() {
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.mipFilter = .linear
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        descriptor.normalizedCoordinates = true
        self.samplerState = device.makeSamplerState(descriptor: descriptor)
    }

    private func setupPlaceholderTexture() {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 2, height: 2, mipmapped: false)
        desc.usage = [.shaderRead]
        placeholderTexture = device.makeTexture(descriptor: desc)
        let darkPixels: [UInt32] = [0xFF0D0D12, 0xFF14141A, 0xFF14141A, 0xFF0D0D12]
        placeholderTexture?.replace(region: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0, withBytes: darkPixels, bytesPerRow: 8)
    }

    // MARK: - Aspect Ratio & Quad Geometry

    struct Vertex {
        var position: SIMD2<Float>
        var texCoord: SIMD2<Float>
    }

    public func toggleAspectRatio() {
        aspectRatioMode = (aspectRatioMode == .pillarbox) ? .widescreen : .pillarbox
        NFSCLogger.shared.info("DISPLAY", "Switched Aspect Ratio Mode: \(aspectRatioMode == .pillarbox ? "16:9 Pillarbox" : "19.5:9 Full Widescreen")")
    }

    private func updateQuadVertices() {
        var xMin: Float = -1.0
        var xMax: Float = 1.0
        var yMin: Float = -1.0
        var yMax: Float = 1.0

        if aspectRatioMode == .pillarbox && viewSize.width > 0 && viewSize.height > 0 {
            // Target game aspect ratio is 16:9
            let targetAspect: Float = 16.0 / 9.0
            let currentAspect: Float = Float(viewSize.width / viewSize.height)

            if currentAspect > targetAspect {
                // Screen is wider than 16:9 (e.g. 19.5:9 on modern iPhones) -> Pillarbox left/right
                let scaleFactor = targetAspect / currentAspect
                xMin = -scaleFactor
                xMax = scaleFactor
            } else if currentAspect < targetAspect {
                // Screen is taller than 16:9 (e.g. iPad 4:3) -> Letterbox top/bottom
                let scaleFactor = currentAspect / targetAspect
                yMin = -scaleFactor
                yMax = scaleFactor
            }
        }

        // 2 Triangles for a full screen quad
        let vertices: [Vertex] = [
            Vertex(position: SIMD2<Float>(xMin, yMax), texCoord: SIMD2<Float>(0.0, 0.0)), // Top-Left
            Vertex(position: SIMD2<Float>(xMin, yMin), texCoord: SIMD2<Float>(0.0, 1.0)), // Bottom-Left
            Vertex(position: SIMD2<Float>(xMax, yMin), texCoord: SIMD2<Float>(1.0, 1.0)), // Bottom-Right

            Vertex(position: SIMD2<Float>(xMin, yMax), texCoord: SIMD2<Float>(0.0, 0.0)), // Top-Left
            Vertex(position: SIMD2<Float>(xMax, yMin), texCoord: SIMD2<Float>(1.0, 1.0)), // Bottom-Right
            Vertex(position: SIMD2<Float>(xMax, yMax), texCoord: SIMD2<Float>(1.0, 0.0))  // Top-Right
        ]

        let bufferSize = vertices.count * MemoryLayout<Vertex>.stride
        self.vertexBuffer = device.makeBuffer(bytes: vertices, length: bufferSize, options: .storageModeShared)
    }

    // MARK: - MTKViewDelegate

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        self.viewSize = size
        updateQuadVertices()
        NFSCLogger.shared.info("DISPLAY", "MTKView drawable size changed to \(Int(size.width))x\(Int(size.height))")
    }

    public func draw(in view: MTKView) {
        _ = inflightSemaphore.wait(timeout: .distantFuture)

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let renderPassDesc = view.currentRenderPassDescriptor,
              let currentDrawable = view.currentDrawable,
              let pipeline = pipelineState,
              let sampler = samplerState,
              let vBuffer = vertexBuffer else {
            inflightSemaphore.signal()
            return
        }

        commandBuffer.addCompletedHandler { [weak self] _ in
            self?.inflightSemaphore.signal()
        }

        // 1. Fetch latest rendered frame texture from native recomp core
        var frameTexture: MTLTexture?
        if let bridge = NFSCBridge.shared() {
            frameTexture = bridge.acquireLatestFrameTexture()
        }
        let activeTexture = frameTexture ?? placeholderTexture

        // 2. Render Quad with aspect-ratio scaling
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDesc) else {
            commandBuffer.commit()
            return
        }

        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(vBuffer, offset: 0, index: 0)
        encoder.setFragmentTexture(activeTexture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()

        // 3. Present Drawable & Commit
        commandBuffer.present(currentDrawable)
        commandBuffer.commit()
    }
}
