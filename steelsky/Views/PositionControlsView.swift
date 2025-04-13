import SwiftUI

struct PositionControlsView: View {
	@Binding var cameraDistance: Float
	@Binding var isMoving: Bool
	@Binding var movementSpeed: Float
	
	var body: some View {
		VStack(spacing: 16) {
			SliderControlView(
				title: "Camera Height",
				value: $cameraDistance,
				range: 6361...6500,
				step: 1,
				displayValue: String(Int(cameraDistance))
			)
			
			HStack {
				Text("Forward Motion")
					.font(.system(size: 14, weight: .medium))
					.foregroundColor(.white)
					.frame(width: 120, alignment: .leading)
				
				Button(action: {}) {
					HStack {
						Image(systemName: "arrow.forward")
						Text("Move Forward")
					}
					.font(.system(size: 14, weight: .medium))
					.foregroundColor(.white)
					.padding(.horizontal, 16)
					.padding(.vertical, 8)
					.background(Color.blue.opacity(0.8))
					.cornerRadius(8)
				}
				.simultaneousGesture(
					DragGesture(minimumDistance: 0)
						.onChanged { _ in
							isMoving = true
						}
						.onEnded { _ in
							isMoving = false
						}
				)
				
				Spacer()
			}
			
			SliderControlView(
				title: "Move Speed",
				value: $movementSpeed,
				range: 0.1...5.0,
				step: 0.1,
				displayValue: String(format: "%.1f", movementSpeed)
			)
		}
	}
}
