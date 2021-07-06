//
//  RealtimeVideoView.swift
//
//  Created by nevyn Bengtsson on 2019-04-2.
//

import UIKit
import Metal
import MetalKit
import AVFoundation
import VideoToolbox
import GLKit
import CoreMotion

/// Renders video by feeding it YUV buffers in realtime.
/// Requires buffers in kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange format.
class RealtimeVideoView : UIView
{
    private var _view : RVVInternal
    var pixels : CVPixelBuffer?
    {
        get { return _view.pixels }
        set { _view.pixels = newValue }
    }
    
    enum DisplayMode
    {
        case aspectFit
        case aspectFill
    }
    
    struct DisplaySettings
    {
        var mirrorHorizontally = false
        var rotation : Float = 0.0
        var displayMode: DisplayMode = .aspectFit
    }
    
    var displaySettings : DisplaySettings
    {
        get { return _view.displaySettings }
        set { _view.displaySettings = newValue}
    }
    
    override init(frame: CGRect)
    {
        _view = createInternal()
        super.init(frame: frame)
        commonInit()
    }
    required init?(coder aDecoder: NSCoder)
    {
        _view = createInternal()
        super.init(coder: aDecoder)
        commonInit()
    }
    
    func commonInit()
    {
        _view.frame = self.bounds
        _view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        self.addSubview(_view)
    }
}

private func metalSupported() -> Bool
{
    return MTLCreateSystemDefaultDevice() != nil
}

private func createInternal() -> RVVInternal
{
    if metalSupported() {
        if let mv = RealtimeVideoMetalView(()) {
            return mv
        }
        print("RealtimeVideoView: Failed to make metal renderer. Falling back to CoreGraphics.")
    }
    return RealtimeVideoDrawingView()
}

protocol RVVInternal : UIView
{
    var pixels : CVPixelBuffer? { get set}
    var displaySettings : RealtimeVideoView.DisplaySettings { get set }
}

class RealtimeVideoDrawingView : UIView, RVVInternal
{
    var pixels: CVPixelBuffer? = nil
    {
        didSet
        {
            DispatchQueue.main.async
            {
                self.setNeedsDisplay()
            }
        }
    }
    var displaySettings = RealtimeVideoView.DisplaySettings()
    {
        didSet {
            DispatchQueue.main.async
            {
                self.setNeedsDisplay()
            }
        }
    }
    
    override func draw(_ rect: CGRect) {
        let ctx = UIGraphicsGetCurrentContext()
        if let pixels = pixels {
            ctx?.saveGState()
            var cgImage : CGImage? = nil
            ctx?.translateBy(x: displaySettings.mirrorHorizontally ? self.bounds.width : 0, y: self.bounds.height)
            ctx?.scaleBy(x: displaySettings.mirrorHorizontally ? -1 : 1, y: -1)
            VTCreateCGImageFromCVPixelBuffer(pixels, options: nil, imageOut: &cgImage)
            if let cgImage = cgImage {
                ctx?.draw(cgImage, in: self.bounds)
            }
            ctx?.restoreGState()
        }
    }
}

#if targetEnvironment(simulator)

class RealtimeVideoMetalView : MTKView, RVVInternal
{
    var pixels: CVPixelBuffer?
    
    var displaySettings = RealtimeVideoView.DisplaySettings()
    
    init?(_: Void)
    {
        fatalError("not implemented in simulator")
    }
    required init(coder: NSCoder)
    {
        fatalError()
    }
}

#else

class RealtimeVideoMetalView : MTKView, RVVInternal
{
    var pixels: CVPixelBuffer? = nil
    var displaySettings = RealtimeVideoView.DisplaySettings()
    
    private let commandQueue : MTLCommandQueue
    private let library : MTLLibrary
    private let textureCache : CVMetalTextureCache
    private var pipelineState : MTLRenderPipelineState!
    
    struct Vertex
    {
        var x, y: Float
        var u, v: Float
    }
    struct Quad
    {
        var bl, br, tl, tr: Vertex
        func packed() -> [Float]
        {
            return [ bl.x, bl.y, bl.u, bl.v, br.x, br.y, br.u, br.v, tl.x, tl.y, tl.u, tl.v, tr.x, tr.y, tr.u, tr.v ]
        }
    }
    var quad = Quad(
        bl: Vertex(x: -1.0, y: -1.0, u: 0.0, v: 1.0),
        br: Vertex(x:  1.0, y: -1.0, u: 1.0, v: 1.0),
        tl: Vertex(x: -1.0, y:  1.0, u: 0.0, v: 0.0),
        tr: Vertex(x:  1.0, y:  1.0, u: 1.0, v: 0.0)
    )
    let vertexBuffer: MTLBuffer
    
    let matrixBuffer: MTLBuffer
    
    required init(coder: NSCoder)
    {
        fatalError()
    }
    init?(_: Void)
    {
        guard
            let d = MTLCreateSystemDefaultDevice(),
            let cq = d.makeCommandQueue()
        else
        {
            return nil
        }
        
        self.commandQueue = cq
        guard let l = d.makeDefaultLibrary() else
        {
            return nil
        }
        self.library = l
        
        var maybeCache : CVMetalTextureCache? = nil
        guard
            CVMetalTextureCacheCreate(
                nil, // allocator
                nil, // cache attributes
                d,
                nil, // texture attributes
                &maybeCache
            ) == kCVReturnSuccess,
            let cache = maybeCache
        else
        {
            return nil
        }
        self.textureCache = cache
        
        let dataSize = 16 * MemoryLayout<Float>.size
        guard
            let vb = d.makeBuffer(length: dataSize, options: []),
            let mb = d.makeBuffer(length: dataSize, options: [])
        else
        {
            return nil
        }
        self.vertexBuffer = vb
        self.matrixBuffer = mb
        
        super.init(frame: CGRect(x: 0, y: 0, width: 100, height: 100), device: d)
        
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        guard let v = library.makeFunction(name: "vertexPassthrough"),
              let f = library.makeFunction(name: "yuvToRgba") else
        {
            return nil
        }
        pipelineDescriptor.vertexFunction = v
        pipelineDescriptor.fragmentFunction = f
        pipelineDescriptor.colorAttachments[0].pixelFormat = self.colorPixelFormat
        guard let ps = try? d.makeRenderPipelineState(descriptor: pipelineDescriptor) else {
            return nil
        }
        self.pipelineState = ps
        self.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        self.isOpaque = false
    }
    
    override func draw(_ rect: CGRect)
    {
        guard let pixels = pixels else {
            // nothing to render
            return
        }
        
        //////// Setup textures
        var maybeLumaTexRef : CVMetalTexture? = nil
        let lumaSize = CGSize(width: CVPixelBufferGetWidthOfPlane(pixels, 0), height: CVPixelBufferGetHeightOfPlane(pixels, 0))
        guard CVMetalTextureCacheCreateTextureFromImage(
            nil, // allocator
            self.textureCache,
            pixels,
            nil, // texture attributes
            MTLPixelFormat.r8Unorm, // one color
            Int(lumaSize.width),
            Int(lumaSize.height),
            0, // planeIndex,
            &maybeLumaTexRef) == kCVReturnSuccess,
            let lumaTexRef = maybeLumaTexRef
        else {
            return
        }
        let lumaTex = CVMetalTextureGetTexture(lumaTexRef)
        
        // sanity check that we're dealing with a 4:2:2 format here
        assert(CVPixelBufferGetWidthOfPlane(pixels, 1) == CVPixelBufferGetWidthOfPlane(pixels, 0)/2)
        
        var maybeChromaTexRef : CVMetalTexture? = nil
        guard CVMetalTextureCacheCreateTextureFromImage(
            nil, // allocator
            self.textureCache,
            pixels,
            nil, // texture attributes
            MTLPixelFormat.rg8Unorm, // two colors
            CVPixelBufferGetWidthOfPlane(pixels, 1),
            CVPixelBufferGetHeightOfPlane(pixels, 1),
            1, // planeIndex,
            &maybeChromaTexRef) == kCVReturnSuccess,
            let chromaTexRef = maybeChromaTexRef
        else {
            return
        }
        let chromaTex = CVMetalTextureGetTexture(chromaTexRef)
        
        //////// setup matrices
        // make 1 world unit = 1 pixel. This gives our world coordinate space the same aspect ratio
        // as the view. Makes it easier to reason about geometry.
        let camera = GLKMatrix4MakeScale(Float(1/drawableSize.width), Float(1/drawableSize.height), 1)
        
        // Rotate
        let rot = (self.displaySettings.rotation/180.0) * Float.pi
        let rotMat = GLKMatrix4MakeZRotation(rot)
        // Scale up image to its original dimensions
        let originalFrameScale = GLKMatrix4MakeScale(Float(lumaSize.width), Float(lumaSize.height), 1)
        // Scale the largest dimension to fill canvas's corresponding dimension ( = aspect fill or fit)
        // Also account for rotation, so we're fitting X in Y if we're 90 or 270deg rotated
        let scaleY = drawableSize.height / lumaSize.height
        let inverseScaleY = drawableSize.width / lumaSize.height
        let scaleX = drawableSize.width / lumaSize.width
        let inverseScaleX = drawableSize.height / lumaSize.width
        let scale = Float(self.displaySettings.displayMode == .aspectFit ? min(scaleY, scaleX) : max(scaleY, scaleX))
        let inverseScale = Float(self.displaySettings.displayMode == .aspectFit ? min(inverseScaleY, inverseScaleX) : max(inverseScaleY, inverseScaleX))
        let rotScale = abs(cos(rot))*scale + abs(sin(rot))*inverseScale
        let aspectFitScaleTransform = GLKMatrix4MakeScale(rotScale, rotScale, 1)
        
        // Mirror horizontally if requested
        let mirror = GLKMatrix4MakeScale(-1, 1, 1) * GLKMatrix4MakeTranslation(1, 0, 0)
        let maybeMirror = self.displaySettings.mirrorHorizontally ? mirror : GLKMatrix4Identity
        // and combine it all into a transform for this quad
        let model = rotMat * maybeMirror * originalFrameScale * aspectFitScaleTransform
        
        // put model transform into world coordinates by multiplying by camera
        var transform = camera * model
        memcpy(matrixBuffer.contents(), &transform.m, MemoryLayout<Float>.size * 16)
        
        //////// setup geometry
        memcpy(vertexBuffer.contents(), quad.packed(), MemoryLayout<Float>.size * 16)

        //////// render
        guard
            let currentDrawable = self.currentDrawable,
            let renderPassDescriptor = self.currentRenderPassDescriptor,
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)
        else
        {
            return
        }
        
        renderEncoder.setRenderPipelineState(pipelineState)
        renderEncoder.setVertexBuffer(self.vertexBuffer, offset: 0, index: 0)
        renderEncoder.setVertexBuffer(self.matrixBuffer, offset: 0, index: 1)
        renderEncoder.setFragmentTexture(lumaTex, index: 0)
        renderEncoder.setFragmentTexture(chromaTex, index: 1)
        
        renderEncoder.drawPrimitives(
            type: .triangleStrip,
            vertexStart: 0,
            vertexCount: 4
        )
        
        renderEncoder.endEncoding()
        commandBuffer.present(currentDrawable)
        commandBuffer.commit()
    }
}

#endif

class RealtimeVideoViewPlayground : NSObject, AVCaptureVideoDataOutputSampleBufferDelegate
{
    var tc: TransitioningContainerViewController!
    let output = AVCaptureVideoDataOutput()
    let capsess = AVCaptureSession()
    let q = DispatchQueue.init(label: "testcam", qos: .userInteractive, attributes: [], autoreleaseFrequency: .inherit, target: nil)
    var rv: RealtimeVideoView! = nil
    let vc = UIViewController()
    let motionManager = CMMotionManager()

    
    init(window: UIWindow)
    {
        super.init()
        
        window.rootViewController = vc
        
        vc.view.backgroundColor = UIColor.purple
        rv = RealtimeVideoView(frame: vc.view.bounds.inset(by: UIEdgeInsets(top: 40, left: 20, bottom: 20, right: 20)))
        rv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        rv.displaySettings.mirrorHorizontally = true
        rv.backgroundColor = UIColor.cyan
        vc.view.addSubview(rv)
        
        
        capsess.beginConfiguration()
        let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)!
        let devicein = try! AVCaptureDeviceInput(device: device)
        capsess.addInput(devicein)
        
        output.alwaysDiscardsLateVideoFrames = true
        
        output.setSampleBufferDelegate(self, queue: q)
        capsess.addOutput(output)
        capsess.commitConfiguration()
        
        let conn = output.connection(with: .video)!
        conn.videoOrientation = .portrait
        
        capsess.startRunning()
        
        vc.view.isUserInteractionEnabled = true
        let pan = UIPanGestureRecognizer(target: self, action: #selector(turn))
        rv.addGestureRecognizer(pan)
        
        NotificationCenter.default.addObserver(self, selector: #selector(didRotate), name: UIApplication.didChangeStatusBarOrientationNotification, object: nil)
        
        if motionManager.isDeviceMotionAvailable
        {
            motionManager.deviceMotionUpdateInterval = 0.025;
            let queue = OperationQueue()
            motionManager.startDeviceMotionUpdates(to: queue, withHandler: { [weak self] (motion, error) -> Void in
                if let attitude = motion?.attitude
                {
                    let camRot = Float(attitude.yaw) * 180.0/Float.pi
                    let deviceRot: Float
                    switch self?.deviceOrient ?? .unknown {
                        case .portrait: deviceRot = 0
                        case .landscapeLeft: deviceRot = -90
                        case .landscapeRight: deviceRot = 90
                        case .portraitUpsideDown: deviceRot = 180
                        default: deviceRot = 0
                    }
                    self?.rv.displaySettings.rotation = deviceRot/2 + -camRot/2
                }
            })
        }
    }
    var count = 0
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection)
    {
        if self.count < 5
        {
            self.count += 1
            DispatchQueue.main.async
            {
                self.rv.pixels = CMSampleBufferGetImageBuffer(sampleBuffer)
                self.count -= 1
            }
        }
    }
    
    @objc func turn(_ grec: UIPanGestureRecognizer)
    {
        rv.displaySettings.rotation = Float(grec.translation(in: vc.view).x)
    }
    var deviceOrient: UIInterfaceOrientation = .unknown
    @objc func didRotate()
    {
        deviceOrient = UIApplication.shared.statusBarOrientation
    }
}
