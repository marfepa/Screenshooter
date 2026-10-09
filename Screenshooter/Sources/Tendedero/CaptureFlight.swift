import AppKit
import QuartzCore

/// Controlador de animaciones espaciales para el Tendedero:
/// 1. Vuelo de despegue (Capture Flight): la captura seleccionada se eleva,
///    se encoge suavemente en una parábola y se cuelga en la línea superior.
/// 2. Caída libre (Fall): al descartar una captura, cae de la cuerda por gravedad.
@MainActor
public final class CaptureFlight {
    private static var activeFlights: [CaptureFlight] = []
    
    private let window: NSWindow
    private let containerLayer = CALayer()
    private let imageLayer = CALayer()
    private let glassLayer = CALayer()
    private var completion: (() -> Void)?
    
    private init(image: CGImage, from fromRect: CGRect, to toRect: CGRect, tilt: Double, screen: NSScreen) {
        // Ventana invisible que cubre la pantalla para animar libremente
        self.window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        
        let root = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        root.wantsLayer = true
        window.contentView = root
        
        guard let rootLayer = root.layer else { return }
        rootLayer.addSublayer(containerLayer)
        
        // Coordenadas relativas a la pantalla del vuelo
        let screenOrigin = screen.frame.origin
        let localFrom = CGRect(
            x: fromRect.origin.x - screenOrigin.x,
            y: fromRect.origin.y - screenOrigin.y,
            width: fromRect.width,
            height: fromRect.height
        )
        containerLayer.frame = localFrom
        containerLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        
        // Capa de imagen
        imageLayer.frame = containerLayer.bounds
        imageLayer.contents = image
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.cornerRadius = 8
        imageLayer.masksToBounds = true
        containerLayer.addSublayer(imageLayer)
        
        // Borde de cristal sutil
        glassLayer.frame = containerLayer.bounds
        glassLayer.cornerRadius = 8
        glassLayer.borderWidth = 1.0
        glassLayer.borderColor = NSColor(white: 1.0, alpha: 0.4).cgColor
        glassLayer.masksToBounds = true
        containerLayer.addSublayer(glassLayer)
        
        window.orderFrontRegardless()
    }
    
    /// Anima una captura despegando desde la pantalla hasta la cuerda del Tendedero.
    public static func fly(
        image: CGImage,
        from fromRect: CGRect,
        to toRect: CGRect,
        tilt: Double,
        screen: NSScreen,
        completion: @escaping () -> Void
    ) {
        let flight = CaptureFlight(image: image, from: fromRect, to: toRect, tilt: tilt, screen: screen)
        activeFlights.append(flight)
        flight.completion = { [weak flight] in
            completion()
            activeFlights.removeAll { $0 === flight }
        }
        flight.animateFly(from: fromRect, to: toRect, tilt: tilt, screen: screen)
    }
    
    /// Anima la caída de una tarjeta descartada de la cuerda.
    public static func fall(
        image: CGImage,
        cardRect: CGRect,
        tilt: Double,
        screen: NSScreen,
        completion: @escaping () -> Void
    ) {
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.isReleasedWhenClosed = false
        
        let root = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        root.wantsLayer = true
        window.contentView = root
        
        guard let rootLayer = root.layer else {
            completion()
            return
        }
        
        let screenOrigin = screen.frame.origin
        let localRect = CGRect(
            x: cardRect.origin.x - screenOrigin.x,
            y: cardRect.origin.y - screenOrigin.y,
            width: cardRect.width,
            height: cardRect.height
        )
        
        let layer = CALayer()
        layer.frame = localRect
        layer.contents = image
        layer.contentsGravity = .resizeAspectFill
        layer.cornerRadius = 8
        layer.masksToBounds = true
        rootLayer.addSublayer(layer)
        
        window.orderFrontRegardless()
        
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.55)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeIn))
        CATransaction.setCompletionBlock {
            window.orderOut(nil)
            window.close()
            completion()
        }
        
        // Movimiento hacia abajo
        let animY = CABasicAnimation(keyPath: "position.y")
        animY.fromValue = layer.position.y
        animY.toValue = layer.position.y - 450
        
        // Rotación mayor al caer
        let animRot = CABasicAnimation(keyPath: "transform.rotation.z")
        animRot.fromValue = tilt * .pi / 180.0
        animRot.toValue = (tilt + 18.0) * .pi / 180.0
        
        // Desvanecimiento
        let animFade = CABasicAnimation(keyPath: "opacity")
        animFade.fromValue = 1.0
        animFade.toValue = 0.0
        
        layer.add(animY, forKey: "fallY")
        layer.add(animRot, forKey: "fallRot")
        layer.add(animFade, forKey: "fallFade")
        
        layer.position.y -= 450
        layer.opacity = 0.0
        
        CATransaction.commit()
    }
    
    private func animateFly(from fromRect: CGRect, to toRect: CGRect, tilt: Double, screen: NSScreen) {
        let screenOrigin = screen.frame.origin
        let localFrom = CGRect(
            x: fromRect.origin.x - screenOrigin.x,
            y: fromRect.origin.y - screenOrigin.y,
            width: fromRect.width,
            height: fromRect.height
        )
        let localTo = CGRect(
            x: toRect.origin.x - screenOrigin.x,
            y: toRect.origin.y - screenOrigin.y,
            width: toRect.width,
            height: toRect.height
        )
        
        let duration: CFTimeInterval = 0.60
        
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        CATransaction.setCompletionBlock { [weak self] in
            guard let self = self else { return }
            self.window.orderOut(nil)
            self.window.close()
            let comp = self.completion
            comp?()
        }
        
        // Trayectoria parabólica (arco hacia arriba y hacia el centro del panel)
        let path = CGMutablePath()
        let startCenter = CGPoint(x: localFrom.midX, y: localFrom.midY)
        let endCenter = CGPoint(x: localTo.midX, y: localTo.midY)
        let midControl = CGPoint(x: (startCenter.x + endCenter.x) / 2, y: max(startCenter.y, endCenter.y) + 30)
        
        path.move(to: startCenter)
        path.addQuadCurve(to: endCenter, control: midControl)
        
        let pathAnim = CAKeyframeAnimation(keyPath: "position")
        pathAnim.path = path
        
        // Cambio de tamaño / escala
        let boundsAnim = CABasicAnimation(keyPath: "bounds")
        boundsAnim.fromValue = NSValue(rect: CGRect(origin: .zero, size: localFrom.size))
        boundsAnim.toValue = NSValue(rect: CGRect(origin: .zero, size: localTo.size))
        
        // Rotación final hacia el tilt natural
        let rotAnim = CABasicAnimation(keyPath: "transform.rotation.z")
        rotAnim.fromValue = 0.0
        rotAnim.toValue = tilt * .pi / 180.0
        
        // Mantener capas internas actualizadas
        let imgBoundsAnim = CABasicAnimation(keyPath: "bounds")
        imgBoundsAnim.fromValue = NSValue(rect: CGRect(origin: .zero, size: localFrom.size))
        imgBoundsAnim.toValue = NSValue(rect: CGRect(origin: .zero, size: localTo.size))
        
        let imgPosAnim = CABasicAnimation(keyPath: "position")
        imgPosAnim.fromValue = NSValue(point: CGPoint(x: localFrom.width / 2, y: localFrom.height / 2))
        imgPosAnim.toValue = NSValue(point: CGPoint(x: localTo.width / 2, y: localTo.height / 2))
        
        containerLayer.add(pathAnim, forKey: "flyPosition")
        containerLayer.add(boundsAnim, forKey: "flyBounds")
        containerLayer.add(rotAnim, forKey: "flyRotation")
        
        imageLayer.add(imgBoundsAnim, forKey: "imgBounds")
        imageLayer.add(imgPosAnim, forKey: "imgPos")
        glassLayer.add(imgBoundsAnim, forKey: "glassBounds")
        glassLayer.add(imgPosAnim, forKey: "glassPos")
        
        containerLayer.position = endCenter
        containerLayer.bounds = CGRect(origin: .zero, size: localTo.size)
        containerLayer.transform = CATransform3DMakeRotation(CGFloat(tilt * .pi / 180.0), 0, 0, 1)
        imageLayer.bounds = CGRect(origin: .zero, size: localTo.size)
        imageLayer.position = CGPoint(x: localTo.width / 2, y: localTo.height / 2)
        glassLayer.bounds = CGRect(origin: .zero, size: localTo.size)
        glassLayer.position = CGPoint(x: localTo.width / 2, y: localTo.height / 2)
        
        CATransaction.commit()
    }
}
