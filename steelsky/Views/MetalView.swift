import SwiftUI
import MetalKit
import UIKit

class MetalViewCoordinator: ObservableObject {
	var metalView: MTKView?
	var renderer: SceneRenderer?
}


struct MetalView: UIViewRepresentable {
	var modelName: String
	var coordinator: MetalViewCoordinator
	
	@Binding var cameraDistance: Float
	@Binding var atmosphereType: Int
	@Binding var timeOfDay: Float
	@Binding var fogDensity: Float
	@Binding var godRayStrength: Float
	@Binding var isMoving: Bool
	@Binding var movementSpeed: Float
	@Binding var isTimeAnimating: Bool
	@Binding var timeCycleSpeed: Float
	
	func makeUIView(context: Context) -> MTKView {
		let mtkView = MTKView()
		mtkView.enableSetNeedsDisplay = false
		mtkView.preferredFramesPerSecond = 60
		mtkView.clearColor = MTLClearColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0)
		mtkView.clearDepth = 1.0
		mtkView.depthStencilPixelFormat = .depth32Float
		
		let renderer = SceneRenderer(metalView: mtkView, modelName: modelName)
		context.coordinator.renderer = renderer
		
		coordinator.metalView = mtkView
		coordinator.renderer = renderer
		
		let panGesture = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
		mtkView.addGestureRecognizer(panGesture)
		
		context.coordinator.startAnimationTimer()
		
		return mtkView
	}
	
	func updateUIView(_ uiView: MTKView, context: Context) {
		context.coordinator.renderer?.setCameraDistance(cameraDistance)
		context.coordinator.renderer?.updateTimeOfDay(timeOfDay)
		
		let atmosphereTypeEnum: SceneRenderer.AtmosphereType = atmosphereType == 0 ? .earth : .mars
		context.coordinator.renderer?.updateAtmosphereType(atmosphereTypeEnum)
		
		context.coordinator.renderer?.updateVolumetricParameters(
			fogDensity: fogDensity,
			godRayStrength: godRayStrength
		)
		
		context.coordinator.isMoving = isMoving
		context.coordinator.movementSpeed = movementSpeed
		context.coordinator.isTimeAnimating = isTimeAnimating
		context.coordinator.timeCycleSpeed = timeCycleSpeed
	}
	
	func makeCoordinator() -> Coordinator {
		Coordinator(timeOfDay: $timeOfDay)
	}
	
	class Coordinator {
		var renderer: SceneRenderer?
		private var lastPanLocation: CGPoint?
		private var animationTimer: Timer?
		@Binding var timeOfDay: Float
		
		var isMoving: Bool = false
		var movementSpeed: Float = 1.0
		var isTimeAnimating: Bool = false
		var timeCycleSpeed: Float = 1.0
		
		init(timeOfDay: Binding<Float>) {
			self._timeOfDay = timeOfDay
		}
		
		func startAnimationTimer() {
			animationTimer = Timer.scheduledTimer(withTimeInterval: 0.033, repeats: true) { [weak self] _ in
				self?.updateAnimation()
			}
		}
		
		func updateAnimation() {
			if isMoving, let renderer = renderer {
				let moveDistance = 0.2 * movementSpeed
				renderer.moveCameraForward(distance: moveDistance)
			}

			if isTimeAnimating {
				timeOfDay += 0.00033 * timeCycleSpeed
				if timeOfDay > 1.0 {
					timeOfDay = 0.0
				}
			}
		}
		
		deinit {
			animationTimer?.invalidate()
		}
		
		@objc func handlePan(_ gesture: UIPanGestureRecognizer) {
			if gesture.state == .began {
				lastPanLocation = gesture.location(in: gesture.view)
				return
			}
			
			guard let lastLocation = lastPanLocation else { return }
			let currentLocation = gesture.location(in: gesture.view)
			
			let deltaX = currentLocation.x - lastLocation.x
			let deltaY = currentLocation.y - lastLocation.y
			
			let rotationX = Float(deltaY) * 0.005
			let rotationY = Float(deltaX) * -0.005
			
			renderer?.updateCameraRotation(rotationX: rotationX, rotationY: rotationY)
			
			lastPanLocation = currentLocation
		}
	}
}

extension MTKView {
	func snapshot() -> UIImage {
		assert(Thread.isMainThread)
		
		if !isPaused {
			draw()
		}
		
		let renderer = UIGraphicsImageRenderer(size: bounds.size)
		let image = renderer.image { ctx in
			self.drawHierarchy(in: bounds, afterScreenUpdates: true)
		}
		
		return image
	}
}
