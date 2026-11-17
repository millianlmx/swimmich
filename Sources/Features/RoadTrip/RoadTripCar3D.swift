import Foundation
import SceneKit
import Metal
import UIKit

/// Renders the bundled 3D car model (USDZ) into sprite sheets — one frame per
/// compass heading — shared by the live map annotation and the export renderer,
/// so the car is a real 3D model in both.
///
/// Two sheets with the same heading convention (`sprite[0]` = nose pointing
/// north/screen-up, `sprite[i]` = heading `i * 360°/count` clockwise):
/// - `sprite(forBearing:)` — top-down view (Uber-style), orthographic.
/// - `chaseSprite(forBearing:)` — rear 3/4 view from behind and above
///   (Google-Maps navigation style), perspective — used by the driving map.
enum RoadTripCar3D {

    /// Number of top-down heading frames (72 = 5° steps).
    static let spriteCount = 72

    /// Number of chase heading frames (36 = 10° steps).
    static let chaseSpriteCount = 36

    /// Flip to true if the car drives backwards in the sprites.
    static var noseFlipped = true

    private static let sprites: [CGImage] = generateSprites()
    private static let chaseSprites: [CGImage] = generateChaseSprites()

    /// Warms the top-down sprite cache (the film's aerial map) synchronously.
    /// Call off the main thread during prepare (or from the renderer, where
    /// it's already warm) so the map leg never blocks on its first appearance.
    static func warm() {
        _ = sprites
    }

    /// Sprite for a compass bearing (radians, north = 0, clockwise).
    static func sprite(forBearing bearing: Double) -> CGImage {
        let frames = sprites
        guard !frames.isEmpty else { return RoadTripCar.render() }
        var normalized = bearing.truncatingRemainder(dividingBy: 2 * .pi)
        if normalized < 0 { normalized += 2 * .pi }
        var index = Int((normalized / (2 * .pi / Double(frames.count))).rounded()) % frames.count
        if index < 0 { index += frames.count }
        return frames[index]
    }

    /// Chase-view sprite for a compass bearing (falls back to the top-down
    /// sheet if the chase render came up blank).
    static func chaseSprite(forBearing bearing: Double) -> CGImage {
        let frames = chaseSprites
        guard !frames.isEmpty else { return sprite(forBearing: bearing) }
        let step = 2 * Double.pi / Double(frames.count)
        var normalized = bearing.truncatingRemainder(dividingBy: 2 * .pi)
        if normalized < 0 { normalized += 2 * .pi }
        let index = Int((normalized / step).rounded()) % frames.count
        return frames[index]
    }

    /// Distance from the top of the chase sprite (y-down fraction of its
    /// height) to the car's ground contact — measured from the rendered pixels
    /// so the preview and the export both anchor the car exactly on its map
    /// position.
    static let chaseContactFraction: Double = {
        guard let first = chaseSprites.first else { return 0.72 }
        return contactFraction(of: first)
    }()

    /// Angular step between chase sprite frames.
    static let chaseYawStep = 2 * Double.pi / Double(chaseSpriteCount)

    /// The sprite frame yaw nearest to `yaw` (for continuous residual rotation).
    static func chaseNearestYaw(_ yaw: Double) -> Double {
        (yaw / chaseYawStep).rounded() * chaseYawStep
    }

    /// Sine of the chase camera's downward pitch (camera at y=1.6 looking at
    /// y=0.35, z = 0.9 + 2.2 ahead).
    private static let chasePitchSine = sin(atan2(1.6 - 0.35, 0.9 + 2.2))

    /// Sprite yaw whose on-screen nose angle equals `angle`, compensating the
    /// perspective compression of the pitched chase camera: a ground direction
    /// yawed β projects to `atan2(sinβ, sin(α)·cosβ)` in the image, so the
    /// inverse is `atan2(sin(α)·sin(angle), cos(angle))`. Without this the car
    /// body sits up to ~25° off the road (worst at 45° of heading).
    static func chaseYaw(forScreenAngle angle: Double) -> Double {
        atan2(chasePitchSine * sin(angle), cos(angle))
    }

    // MARK: - Generation

    /// Loads the model, recolors it, and returns a scene whose root holds a
    /// single car node: centered at the origin, bottom at y = 0, scaled to
    /// unit length, nose on +Z. Lights included.
    private static func makeCarScene() -> (SCNScene, SCNNode)? {
        guard let url = Bundle.main.url(forResource: "TeslaCar", withExtension: "usdz"),
              let scene = loadScene(url: url) else {
            print("[RoadTripCar3D] model not found or failed to load")
            return nil
        }

        recolor(scene.rootNode)

        // Move all root children under a single car node we can transform.
        let carNode = SCNNode()
        for child in scene.rootNode.childNodes {
            carNode.addChildNode(child)
        }

        // Center + scale to unit length, long axis aligned to Z (screen-up).
        normalize(carNode)

        let renderScene = SCNScene()
        renderScene.rootNode.addChildNode(carNode)
        renderScene.background.contents = UIColor.clear

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 900
        renderScene.rootNode.addChildNode(ambient)

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 1300
        key.light?.color = UIColor.white
        key.position = SCNVector3(0, 10, 0)
        key.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
        renderScene.rootNode.addChildNode(key)

        return (renderScene, carNode)
    }

    /// Renders `count` heading frames by yawing the car under a fixed camera.
    private static func renderFrames(
        scene: SCNScene,
        carNode: SCNNode,
        camera: SCNCamera,
        cameraPosition: SCNVector3,
        lookAt: SCNVector3,
        up: SCNVector3,
        size: CGSize,
        count: Int
    ) -> [CGImage] {
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = cameraPosition
        cameraNode.look(at: lookAt, up: up, localFront: SCNVector3(0, 0, -1))
        scene.rootNode.addChildNode(cameraNode)

        guard let device = MTLCreateSystemDefaultDevice() else { return [] }
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = cameraNode
        renderer.autoenablesDefaultLighting = false

        let step = 2 * Double.pi / Double(count)
        let baseY = (noseFlipped ? Float.pi : 0)
        var frames: [CGImage] = []
        frames.reserveCapacity(count)
        for i in 0..<count {
            // Nose points at compass bearing θ when rotation.y = -θ.
            carNode.eulerAngles.y = baseY - Float(Double(i) * step)
            let snapshot = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
            if let cg = snapshot.cgImage {
                frames.append(cg)
            }
        }
        return frames
    }

    private static func generateSprites() -> [CGImage] {
        guard let (scene, carNode) = makeCarScene() else { return [] }

        // Top-down camera with a slight tilt (Uber-style).
        let camera = SCNCamera()
        camera.usesOrthographicProjection = true
        camera.orthographicScale = 0.8
        camera.zNear = 0.1
        camera.zFar = 100

        return validate(
            renderFrames(
                scene: scene, carNode: carNode, camera: camera,
                cameraPosition: SCNVector3(0, 8, -1.2),
                lookAt: SCNVector3(0, 0, 0), up: SCNVector3(0, 0, 1),
                size: CGSize(width: 512, height: 512), count: spriteCount
            ),
            label: "top-down"
        )
    }

    private static func generateChaseSprites() -> [CGImage] {
        guard let (scene, carNode) = makeCarScene() else { return [] }

        // Low rear camera, tight framing: behind and slightly above the car,
        // looking forward — the driving map's chase view. The car fills a good
        // chunk of the frame so the sprite stays crisp at large display sizes.
        let camera = SCNCamera()
        camera.zNear = 0.05
        camera.zFar = 100
        camera.fieldOfView = 38

        return validate(
            renderFrames(
                scene: scene, carNode: carNode, camera: camera,
                cameraPosition: SCNVector3(0, 1.6, -2.2),
                lookAt: SCNVector3(0, 0.35, 0.9), up: SCNVector3(0, 1, 0),
                size: CGSize(width: 512, height: 512), count: chaseSpriteCount
            ),
            label: "chase"
        )
    }

    /// Fraction of the sprite height (from the top) where the car's ground
    /// contact sits: the lowest row of visible pixels (the tires).
    private static func contactFraction(of image: CGImage) -> Double {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return 0.72 }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0.72 }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Buffer rows run bottom-up (CG origin); find the lowest visible row.
        for row in 0..<height {
            let base = row * width * 4
            var visible = false
            for x in 0..<width where pixels[base + x * 4 + 3] > 16 {
                visible = true
                break
            }
            if visible {
                let fromBottom = Double(row) + 0.5
                return min(max(1.0 - fromBottom / Double(height), 0.1), 0.95)
            }
        }
        return 0.72
    }

    /// Guard: a blank first frame (car off-camera / not rendered) means the
    /// sprites are invisible — fall back to the procedural car (or, for the
    /// chase sheet, to the top-down sheet).
    private static func validate(_ frames: [CGImage], label: String) -> [CGImage] {
        if frames.isEmpty || !hasVisibleContent(frames[0]) {
            print("[RoadTripCar3D] \(label) sprites blank — falling back")
            return []
        }
        print("[RoadTripCar3D] generated \(frames.count) \(label) sprites")
        return frames
    }

    /// Cheap "is anything drawn" probe: downsamples the image to 1×1 and checks
    /// the resulting alpha.
    private static func hasVisibleContent(_ image: CGImage) -> Bool {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return pixel[3] > 0
    }

    private static func loadScene(url: URL) -> SCNScene? {
        try? SCNScene(url: url, options: [.checkConsistency: false])
    }

    /// Recolors the body paint (materials named `primary*`, the factory green)
    /// to a metallic silver-gray. Glass, wheels, chrome, lights stay untouched.
    private static func recolor(_ node: SCNNode) {
        if let geometry = node.geometry {
            for material in geometry.materials {
                let name = material.name ?? ""
                if name.hasPrefix("primary") {
                    material.diffuse.contents = UIColor(white: 0.24, alpha: 1)
                    material.metalness.contents = NSNumber(value: 1.0)
                    material.roughness.contents = NSNumber(value: 0.35)
                }
            }
        }
        for child in node.childNodes { recolor(child) }
    }

    /// Centers the car on the origin (bottom at y=0), scales the long
    /// horizontal axis to length 1, and rotates the long axis onto Z.
    private static func normalize(_ node: SCNNode) {
        let (boxMin, boxMax) = node.boundingBox
        let size = SCNVector3(boxMax.x - boxMin.x, boxMax.y - boxMin.y, boxMax.z - boxMin.z)
        print("[RoadTripCar3D] bounding size \(size.x) × \(size.y) × \(size.z)")

        // Center (x, z) at origin, bottom at y = 0.
        node.position = SCNVector3(-(boxMin.x + boxMax.x) / 2, -boxMin.y, -(boxMin.z + boxMax.z) / 2)

        let length = Swift.max(size.x, size.z)
        let scale = length > 0 ? 1.0 / length : 1.0
        node.scale = SCNVector3(scale, scale, scale)

        if size.x > size.z {
            node.eulerAngles.y = Float.pi / 2
        }
    }
}
