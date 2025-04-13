import SwiftUI

struct LightingControlsView: View {
	@Binding var atmosphereType: Int
	@Binding var fogDensity: Float
	@Binding var godRayStrength: Float
	
	var body: some View {
		VStack(spacing: 16) {
			HStack {
				Text("Atmosphere")
					.font(.system(size: 14, weight: .medium))
					.foregroundColor(.white)
					.frame(width: 120, alignment: .leading)
				
				Picker("", selection: $atmosphereType) {
					Text("Earth").tag(0)
					Text("Mars").tag(1)
				}
				.pickerStyle(SegmentedPickerStyle())
				.background(Color.white.opacity(0.1))
				.cornerRadius(8)
			}
			
			SliderControlView(
				title: "Fog Density",
				value: $fogDensity,
				range: 0...0.1,
				step: 0.001,
				displayValue: String(format: "%.3f", fogDensity)
			)
			
			SliderControlView(
				title: "God Ray Strength",
				value: $godRayStrength,
				range: 0...2,
				step: 0.05,
				displayValue: String(format: "%.2f", godRayStrength)
			)
		}
	}
}
