import SwiftUI
import SwiftData
import MetalKit

struct GalleryControlsView: View {
	var galleryItems: [GalleryItem]
	@State private var showGallery = false
	@State private var isCapturing = false
	
	var galleryViewModel: GalleryViewModel
	var metalViewCoordinator: MetalViewCoordinator
	var settingsProvider: () -> (SIMD3<Float>, SIMD2<Float>, Int, Float, Float, Float, Float, Float)
	var onRestoreState: (GalleryItem) -> Void
	
	var body: some View {
		VStack(spacing: 16) {
			HStack {
				Text("Gallery")
					.font(.system(size: 18, weight: .semibold))
					.foregroundColor(.white)
				Spacer()
			}
			
			Button(action: {
				captureCurrentView()
			}) {
				HStack {
					if isCapturing {
						ProgressView()
							.progressViewStyle(CircularProgressViewStyle(tint: .white))
							.frame(width: 20, height: 20)
					} else {
						Image(systemName: "camera.fill")
							.font(.system(size: 20))
					}
					Text(isCapturing ? "Capturing..." : "Capture Current View")
						.font(.system(size: 16, weight: .medium))
				}
				.foregroundColor(.white)
				.padding(.vertical, 12)
				.padding(.horizontal, 20)
				.background(
					RoundedRectangle(cornerRadius: 10)
						.fill(isCapturing ? Color.gray.opacity(0.8) : Color.blue.opacity(0.8))
				)
			}
			.disabled(isCapturing)
			
			Button(action: { showGallery = true }) {
				HStack {
					Image(systemName: "photo.on.rectangle")
						.font(.system(size: 20))
					Text("Show Gallery")
						.font(.system(size: 16, weight: .medium))
				}
				.foregroundColor(.white)
				.padding(.vertical, 12)
				.padding(.horizontal, 20)
				.background(
					RoundedRectangle(cornerRadius: 10)
						.fill(Color.green.opacity(0.8))
				)
			}
			.disabled(galleryItems.isEmpty || isCapturing)
			.opacity((galleryItems.isEmpty || isCapturing) ? 0.5 : 1.0)
			
			Text("Saved captures: \(galleryItems.count)")
				.font(.system(size: 14))
				.foregroundColor(.gray)
				.padding(.top, 5)
		}
		.sheet(isPresented: $showGallery) {
			GalleryView(
				galleryItems: galleryItems,
				galleryViewModel: galleryViewModel,
				onRestoreState: onRestoreState
			)
		}
	}
	
	private func captureCurrentView() {
		guard let metalView = metalViewCoordinator.metalView else {
			print("MetalView reference is nil")
			return
		}
		
		isCapturing = true
		
		let (cameraPos, cameraRot, atmType, tod, fogDens, godRay, moveSpeed, timeSpeed) = settingsProvider()
		
		galleryViewModel.captureCurrentState(
			metalView: metalView,
			cameraPosition: cameraPos,
			cameraRotation: cameraRot,
			atmosphereType: atmType,
			timeOfDay: tod,
			fogDensity: fogDens,
			godRayStrength: godRay,
			movementSpeed: moveSpeed,
			timeCycleSpeed: timeSpeed
		)
		
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
			self.isCapturing = false
		}
	}
}
