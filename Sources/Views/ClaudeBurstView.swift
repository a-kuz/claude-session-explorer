// Claude Burst — a native Metal port of @claude-ds/burst: the animated engraved
// Claude star plate, used as the app's loader. Shaders live in ClaudeBurst.metal;
// this file drives the animation (spin / tilt / ray-length wave) on the CPU and
// pushes uniforms per frame. The SDF of the star polygon is baked into a texture
// once at init; every frame is a single fullscreen raymarch draw.

import SwiftUI
import MetalKit

// MARK: - Options

struct ClaudeBurstOptions: Equatable {
    enum Mode { case loader, idle }

    var mode: Mode = .loader
    var zoom: Float = 1                                    // 0.4..3
    var face: SIMD3<Float> = [0.741, 0.388, 0.290]         // terracotta plate
    var inset: SIMD3<Float> = [0.965, 0.957, 0.929]        // cream engraving
    var glow: Float = 0                                    // 0..1.2
    var engraveDepth: Float = 0.06
    var bare = false                                       // star only, no plate
    var rim = false
    var iridescence = false
    var pulse = false
}

// MARK: - Ray-length wave data (from the official loading animation)

private enum BurstData {
    static let ang12: [Float] = [0.2619, 0.7678, 1.0647, 1.6580, 2.1468, 2.5309,
                                 3.1416, 3.7003, 4.2236, 4.8692, 5.4455, 6.1435]
    static let lenSVG: [Float] = [0.922, 0.947, 0.922, 0.954, 0.960, 0.918,
                                  0.953, 0.949, 1.000, 0.871, 0.901, 0.891]
    static let vidAng: [Float] = [0.3665, 0.8552, 1.1345, 1.6581, 2.0769, 2.4609,
                                  2.9845, 3.6128, 4.1539, 4.8695, 5.5152, 6.2657]
    static let rayLen: [[Float]] = [
        [0.859,0.847,0.721,0.653,0.703,0.741,0.856,0.857,0.871,0.736,0.772,0.804],
        [0.859,0.896,0.756,0.660,0.679,0.701,0.809,0.857,0.871,0.736,0.772,0.804],
        [0.859,0.915,0.841,0.700,0.655,0.635,0.717,0.857,0.871,0.736,0.772,0.804],
        [0.859,0.915,0.841,0.700,0.655,0.635,0.717,0.857,0.871,0.736,0.772,0.804],
        [0.859,0.915,0.887,0.733,0.661,0.611,0.675,0.837,0.871,0.692,0.772,0.804],
        [0.859,0.915,0.907,0.813,0.703,0.589,0.603,0.739,0.871,0.601,0.772,0.804],
        [0.859,0.915,0.907,0.813,0.703,0.589,0.603,0.739,0.871,0.601,0.772,0.804],
        [0.859,0.915,0.907,0.857,0.736,0.595,0.577,0.692,0.833,0.557,0.772,0.804],
        [0.859,0.915,0.907,0.948,0.819,0.635,0.555,0.615,0.729,0.485,0.751,0.804],
        [0.859,0.915,0.907,0.948,0.819,0.635,0.555,0.615,0.729,0.485,0.751,0.804],
        [0.859,0.915,0.907,0.956,0.864,0.665,0.561,0.587,0.680,0.459,0.707,0.804],
        [0.859,0.915,0.907,0.956,0.955,0.741,0.603,0.563,0.599,0.436,0.631,0.772],
        [0.859,0.915,0.907,0.956,0.955,0.741,0.603,0.563,0.599,0.436,0.631,0.772],
        [0.852,0.915,0.907,0.956,0.955,0.784,0.636,0.569,0.569,0.443,0.603,0.724],
        [0.764,0.915,0.907,0.956,0.955,0.869,0.717,0.615,0.544,0.485,0.580,0.647],
        [0.764,0.915,0.907,0.956,0.955,0.869,0.717,0.615,0.544,0.485,0.580,0.647],
        [0.724,0.915,0.907,0.956,0.955,0.901,0.761,0.649,0.551,0.519,0.585,0.619],
        [0.655,0.847,0.907,0.956,0.955,0.901,0.855,0.739,0.599,0.601,0.631,0.595],
        [0.655,0.847,0.907,0.956,0.955,0.901,0.855,0.739,0.599,0.601,0.631,0.595],
        [0.631,0.799,0.907,0.948,0.955,0.901,0.896,0.788,0.636,0.645,0.664,0.601],
        [0.609,0.719,0.841,0.948,0.955,0.901,0.901,0.857,0.729,0.736,0.751,0.647],
        [0.609,0.719,0.841,0.948,0.955,0.901,0.901,0.857,0.729,0.736,0.751,0.647],
        [0.615,0.691,0.796,0.904,0.955,0.901,0.901,0.857,0.780,0.736,0.772,0.683],
        [0.655,0.665,0.721,0.813,0.953,0.901,0.901,0.857,0.871,0.736,0.772,0.772],
        [0.655,0.665,0.721,0.813,0.953,0.901,0.901,0.857,0.871,0.736,0.772,0.772],
        [0.687,0.671,0.695,0.771,0.911,0.901,0.901,0.857,0.871,0.736,0.772,0.804],
        [0.764,0.719,0.671,0.701,0.819,0.869,0.901,0.857,0.871,0.736,0.772,0.804],
        [0.764,0.719,0.671,0.701,0.819,0.869,0.901,0.857,0.871,0.736,0.772,0.804],
        [0.808,0.755,0.677,0.676,0.776,0.827,0.901,0.857,0.871,0.736,0.772,0.804],
        [0.859,0.847,0.721,0.653,0.703,0.741,0.855,0.857,0.871,0.736,0.772,0.804],
    ]

    // Wave frames with duplicates collapsed (uniform motion), and a nearest-angle
    // map from the 12 geometry rays to the video's ray ordering.
    static let rayUnique: [[Float]] = rayLen.enumerated().filter { i, r in
        i == 0 || r != rayLen[i - 1]
    }.map(\.element)

    static let map: [Int] = ang12.map { a in
        var best = 0; var bd: Float = 9
        for (j, va) in vidAng.enumerated() {
            let d = abs(a - va); let ad = min(d, 2 * Float.pi - d)
            if ad < bd { bd = ad; best = j }
        }
        return best
    }
}

// MARK: - Renderer

// Layout mirrors BurstUniforms in ClaudeBurst.metal (float4 ×2, float2 ×2, floats).
private struct BurstUniforms {
    var cream: SIMD4<Float> = .zero
    var terra: SIMD4<Float> = .zero
    var res: SIMD2<Float> = .zero
    var cam: SIMD2<Float> = .zero
    var zoom: Float = 1
    var hf: Float = 1.25
    var hz: Float = 0.10
    var n: Float = 4.5
    var bevel: Float = 0.03
    var cut: Float = 0.06
    var glow: Float = 0
    var spec: Float = 0.16
    var amb: Float = 0.42
    var fresnel: Float = 0
    var irid: Float = 0
    var pulse: Float = 0
    var nobox: Float = 0
    var wave: Float = 0
}

final class BurstRenderer: NSObject, MTKViewDelegate {
    var options = ClaudeBurstOptions()

    private let queue: MTLCommandQueue
    private let mainPipeline: MTLRenderPipelineState
    private let sdfTexture: MTLTexture

    // Animation timing (matches the web engine).
    private let t0 = CACurrentMediaTime()
    private var lastTm: Float = 0
    private var modeMix: Float
    private static let spinPeriod: Float = 14.0, spinDur: Float = 2.2, spinTurns: Float = 3
    private static let idleGap: Float = 16.0, idleBurst: Float = 6.0
    private static let idleFade: Float = 1.6, idleSpeed: Float = 0.28
    private static let modeFadeDur: Float = 0.7
    private static let baseYaw: Float = -0.42, basePitch: Float = 0.34

    init?(device: MTLDevice, sampleCount: Int, options: ClaudeBurstOptions) {
        guard let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let vertexFn = library.makeFunction(name: "burstVertex"),
              let bakeFn = library.makeFunction(name: "burstBakeFragment"),
              let mainFn = library.makeFunction(name: "burstFragment")
        else { return nil }
        self.queue = queue
        self.options = options
        self.modeMix = options.mode == .loader ? 1 : 0

        let mainDesc = MTLRenderPipelineDescriptor()
        mainDesc.vertexFunction = vertexFn
        mainDesc.fragmentFunction = mainFn
        mainDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        mainDesc.rasterSampleCount = sampleCount

        // One-time SDF bake of the star polygon into an r16Float texture.
        let sdfRes = 1024
        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r16Float, width: sdfRes, height: sdfRes, mipmapped: false)
        texDesc.usage = [.renderTarget, .shaderRead]
        texDesc.storageMode = .private
        let bakeDesc = MTLRenderPipelineDescriptor()
        bakeDesc.vertexFunction = vertexFn
        bakeDesc.fragmentFunction = bakeFn
        bakeDesc.colorAttachments[0].pixelFormat = .r16Float

        guard let mainPipeline = try? device.makeRenderPipelineState(descriptor: mainDesc),
              let bakePipeline = try? device.makeRenderPipelineState(descriptor: bakeDesc),
              let sdfTexture = device.makeTexture(descriptor: texDesc)
        else { return nil }
        self.mainPipeline = mainPipeline
        self.sdfTexture = sdfTexture

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = sdfTexture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        enc.setRenderPipelineState(bakePipeline)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cmd.commit()

        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    private static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = max(0, min(1, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    // Quintic-eased triple turn at the start of every 14s period.
    private static func spinYaw(_ t: Float) -> Float {
        let ph = t.truncatingRemainder(dividingBy: spinPeriod)
        guard ph < spinDur else { return 0 }
        let u = ph / spinDur
        let e = u * u * u * (u * (u * 6 - 15) + 10)
        return 2 * .pi * spinTurns * e
    }

    // Idle: a wave burst every 16s; loader: the wave runs continuously.
    private static func idleAmp(_ t: Float) -> Float {
        let ph = t.truncatingRemainder(dividingBy: idleGap)
        guard ph <= idleBurst else { return 0 }
        return smoothstep(0, idleFade, ph) * (1 - smoothstep(idleBurst - idleFade, idleBurst, ph))
    }

    private func scaleBuffer(phase tm: Float, amp: Float) -> [Float] {
        guard amp > 0.0001 else { return [Float](repeating: 1, count: 12) }
        let frames = BurstData.rayUnique
        let nf = frames.count
        let ph = tm.truncatingRemainder(dividingBy: 1)
        let f = (ph < 0 ? ph + 1 : ph) * Float(nf)
        let i0 = Int(f) % nf, i1 = (i0 + 1) % nf
        let fr = f - f.rounded(.down)
        return (0..<12).map { k in
            let vj = BurstData.map[k]
            let v = frames[i0][vj] + (frames[i1][vj] - frames[i0][vj]) * fr
            let target = v / BurstData.lenSVG[k]
            return 1 + (target - 1) * amp
        }
    }

    func draw(in view: MTKView) {
        guard let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }

        let tm = Float(CACurrentMediaTime() - t0)
        let dt = min(0.05, max(0, tm - lastTm)); lastTm = tm
        let target: Float = options.mode == .loader ? 1 : 0
        let step = dt / Self.modeFadeDur
        modeMix += max(-step, min(step, target - modeMix))

        let idle = Self.idleAmp(tm)
        let waveAmp = idle + (1 - idle) * modeMix
        let idlePh = tm.truncatingRemainder(dividingBy: Self.idleGap)
        let wavePhase = idlePh * Self.idleSpeed * (1 - modeMix) + tm * modeMix

        let yaw = Self.baseYaw + Self.spinYaw(tm) * modeMix + 0.10 * sin(tm * 0.23)
        let pitch = max(-1.3, min(1.3, Self.basePitch + 0.06 * sin(tm * 0.17 + 1.3)))

        var u = BurstUniforms()
        u.cream = SIMD4(options.inset, 0)
        u.terra = SIMD4(options.face, 0)
        u.res = SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height))
        u.cam = SIMD2(yaw, pitch)
        u.zoom = max(0.4, min(3, options.zoom))
        u.cut = options.engraveDepth
        u.glow = options.glow
        u.fresnel = options.rim ? 1 : 0
        u.irid = options.iridescence ? 1 : 0
        u.pulse = options.pulse ? 1 : 0
        u.nobox = options.bare ? 1 : 0
        u.wave = tm

        let scales = scaleBuffer(phase: wavePhase, amp: waveAmp)

        enc.setRenderPipelineState(mainPipeline)
        withUnsafeBytes(of: &u) { enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
        scales.withUnsafeBytes { enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
        enc.setFragmentTexture(sdfTexture, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }
}

// MARK: - SwiftUI

private struct ClaudeBurstMetalView: NSViewRepresentable {
    let options: ClaudeBurstOptions

    func makeCoordinator() -> BurstRenderer? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let samples = device.supportsTextureSampleCount(4) ? 4 : 1
        return BurstRenderer(device: device, sampleCount: samples, options: options)
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm
        view.sampleCount = view.device?.supportsTextureSampleCount(4) == true ? 4 : 1
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.preferredFramesPerSecond = 60
        view.layer?.isOpaque = false
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator?.options = options
    }
}

/// The app's loader: the animated Claude star. Falls back to a plain
/// `ProgressView` on machines without Metal.
struct ClaudeBurstView: View {
    var options = ClaudeBurstOptions()

    private static let metalAvailable = MTLCreateSystemDefaultDevice() != nil

    var body: some View {
        if Self.metalAvailable {
            ClaudeBurstMetalView(options: options)
        } else {
            ProgressView()
        }
    }
}
