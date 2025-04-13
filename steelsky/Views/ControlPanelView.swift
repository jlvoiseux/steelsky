import SwiftUI

struct ControlPanelView: View {
	@Binding var cameraDistance: Float
	@Binding var atmosphereType: Int
	@Binding var timeOfDay: Float
	@Binding var fogDensity: Float
	@Binding var godRayStrength: Float
	@Binding var isMoving: Bool
	@Binding var movementSpeed: Float
	@Binding var isTimeAnimating: Bool
	@Binding var selectedTab: Int
	@Binding var timeCycleSpeed: Float
	
	var galleryItems: [GalleryItem]
	var galleryViewModel: GalleryViewModel?
	var metalViewCoordinator: MetalViewCoordinator
	var settingsProvider: () -> (SIMD3<Float>, SIMD2<Float>, Int, Float, Float, Float, Float, Float)
	var onRestoreState: (GalleryItem) -> Void
	
	var body: some View {
		VStack(spacing: 0) {
			HStack {
				TabButtonView(title: "Position", isSelected: selectedTab == 0) {
					selectedTab = 0
				}
				
				TabButtonView(title: "Lighting", isSelected: selectedTab == 1) {
					selectedTab = 1
				}
				
				TabButtonView(title: "Time", isSelected: selectedTab == 2) {
					selectedTab = 2
				}
				
				TabButtonView(title: "Gallery", isSelected: selectedTab == 3) {
					selectedTab = 3
				}
			}
			.padding(.horizontal, 12)
			.padding(.top, 10)
			
			VStack(spacing: 15) {
				switch selectedTab {
				case 0:
					PositionControlsView(
						cameraDistance: $cameraDistance,
						isMoving: $isMoving,
						movementSpeed: $movementSpeed
					)
				case 1:
					LightingControlsView(
						atmosphereType: $atmosphereType,
						fogDensity: $fogDensity,
						godRayStrength: $godRayStrength
					)
				case 2:
					TimeControlsView(
						timeOfDay: $timeOfDay,
						isTimeAnimating: $isTimeAnimating,
						timeCycleSpeed: $timeCycleSpeed
					)
				case 3:
					if let viewModel = galleryViewModel {
						GalleryControlsView(
							galleryItems: galleryItems,
							galleryViewModel: viewModel,
							metalViewCoordinator: metalViewCoordinator,
							settingsProvider: settingsProvider,
							onRestoreState: onRestoreState
						)
					} else {
						Text("Gallery not available")
							.foregroundColor(.white)
					}
				default:
					EmptyView()
				}
			}
			.padding(.horizontal, 15)
			.padding(.vertical, 12)
		}
		.background(
			RoundedRectangle(cornerRadius: 15)
				.fill(Color.black.opacity(0.7))
				.shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 5)
		)
		.padding(.horizontal)
		.padding(.bottom, 5)
	}
}
