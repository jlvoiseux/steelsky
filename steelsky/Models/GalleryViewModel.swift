import SwiftUI
import SwiftData
import MetalKit

@Observable
class GalleryViewModel {
	private var modelContext: ModelContext
	
	init(modelContext: ModelContext) {
		self.modelContext = modelContext
	}
	
	func captureCurrentState(metalView: MTKView,
						   cameraPosition: SIMD3<Float>,
						   cameraRotation: SIMD2<Float>,
						   atmosphereType: Int,
						   timeOfDay: Float,
						   fogDensity: Float,
						   godRayStrength: Float,
						   movementSpeed: Float,
						   timeCycleSpeed: Float) {
		
		let snapshot = captureMetalView(metalView)
		
		guard let imageData = snapshot.jpegData(compressionQuality: 0.8) else {
			print("Failed to create JPEG data")
			return
		}
		
		DispatchQueue.main.async { [weak self] in
			guard let self = self else { return }
			
			let newItem = GalleryItem(
				timestamp: Date(),
				thumbnail: imageData,
				cameraPositionX: cameraPosition.x,
				cameraPositionY: cameraPosition.y,
				cameraPositionZ: cameraPosition.z,
				cameraRotationX: cameraRotation.x,
				cameraRotationY: cameraRotation.y,
				atmosphereType: atmosphereType,
				timeOfDay: timeOfDay,
				fogDensity: fogDensity,
				godRayStrength: godRayStrength,
				movementSpeed: movementSpeed,
				timeCycleSpeed: timeCycleSpeed
			)
			
			self.modelContext.insert(newItem)
			try? self.modelContext.save()
		}
	}
	
	func deleteItem(_ item: GalleryItem) {
		modelContext.delete(item)
		try? modelContext.save()
	}
	
	private func captureMetalView(_ view: MTKView) -> UIImage {
		if !Thread.isMainThread {
			var resultImage: UIImage?
			let semaphore = DispatchSemaphore(value: 0)
			
			DispatchQueue.main.async {
				resultImage = self.captureMetalView(view)
				semaphore.signal()
			}
			
			semaphore.wait()
			return resultImage ?? UIImage()
		}
		
		view.draw()
		
		let renderer = UIGraphicsImageRenderer(bounds: view.bounds)
		return renderer.image { ctx in
			view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
		}
	}
}
