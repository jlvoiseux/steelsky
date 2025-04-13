import SwiftUI
import SwiftData
import MetalKit

struct ContentView: View {
	@State private var cameraDistance: Float = 6361
	@State private var atmosphereType: Int = 0
	@State private var timeOfDay: Float = 0.5
	@State private var fogDensity: Float = 0.02
	@State private var godRayStrength: Float = 0.7
	@State private var isMoving: Bool = false
	@State private var movementSpeed: Float = 1.0
	@State private var isTimeAnimating: Bool = false
	@State private var selectedTab: Int = 0
	@State private var timeCycleSpeed: Float = 1.0
	
	@StateObject private var metalViewCoordinator = MetalViewCoordinator()
	
	@Environment(\.modelContext) private var modelContext
	@Query private var galleryItems: [GalleryItem]
	
	@State private var galleryViewModel: GalleryViewModel?
	
	var body: some View {
		ZStack {
			MetalView(
				modelName: "planet",
				coordinator: metalViewCoordinator,
				cameraDistance: $cameraDistance,
				atmosphereType: $atmosphereType,
				timeOfDay: $timeOfDay,
				fogDensity: $fogDensity,
				godRayStrength: $godRayStrength,
				isMoving: $isMoving,
				movementSpeed: $movementSpeed,
				isTimeAnimating: $isTimeAnimating,
				timeCycleSpeed: $timeCycleSpeed
			)
			.edgesIgnoringSafeArea(.all)
			.onAppear {
 				if galleryViewModel == nil {
					galleryViewModel = GalleryViewModel(modelContext: modelContext)
				}
			}
			
			VStack {
				Spacer()
				
				ControlPanelView(
					cameraDistance: $cameraDistance,
					atmosphereType: $atmosphereType,
					timeOfDay: $timeOfDay,
					fogDensity: $fogDensity,
					godRayStrength: $godRayStrength,
					isMoving: $isMoving,
					movementSpeed: $movementSpeed,
					isTimeAnimating: $isTimeAnimating,
					selectedTab: $selectedTab,
					timeCycleSpeed: $timeCycleSpeed,
					galleryItems: galleryItems,
					galleryViewModel: galleryViewModel,
					metalViewCoordinator: metalViewCoordinator,
					settingsProvider: getCurrentSettings,
					onRestoreState: restoreState
				)
			}
		}
	}
	
	func getCurrentSettings() -> (SIMD3<Float>, SIMD2<Float>, Int, Float, Float, Float, Float, Float) {
		let cameraPos = metalViewCoordinator.renderer?.getCameraPosition() ?? SIMD3<Float>(0, cameraDistance, 0)
		let cameraRot = metalViewCoordinator.renderer?.getCameraRotation() ?? SIMD2<Float>(0, 0)
		
		return (
			cameraPos,
			cameraRot,
			atmosphereType,
			timeOfDay,
			fogDensity,
			godRayStrength,
			movementSpeed,
			timeCycleSpeed
		)
	}
	
	func restoreState(from item: GalleryItem) {
		cameraDistance = item.cameraPositionY
		atmosphereType = item.atmosphereType
		timeOfDay = item.timeOfDay
		fogDensity = item.fogDensity
		godRayStrength = item.godRayStrength
		movementSpeed = item.movementSpeed
		timeCycleSpeed = item.timeCycleSpeed
		
		if let renderer = metalViewCoordinator.renderer {
			let fullPosition = SIMD3<Float>(item.cameraPositionX, item.cameraPositionY, item.cameraPositionZ)
			let fullRotation = SIMD2<Float>(item.cameraRotationX, item.cameraRotationY)
			renderer.setCameraPosition(fullPosition)
			renderer.setCameraRotation(fullRotation)
		}
		
		isMoving = false
		isTimeAnimating = false
	}
}
