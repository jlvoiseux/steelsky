import SwiftUI

struct SliderControlView: View {
	var title: String
	@Binding var value: Float
	var range: ClosedRange<Float>
	var step: Float
	var displayValue: String
	
	var body: some View {
		HStack {
			Text(title)
				.font(.system(size: 14, weight: .medium))
				.foregroundColor(.white)
				.frame(width: 120, alignment: .leading)
			
			Slider(value: $value, in: range, step: step)
				.accentColor(.blue)
				.background(Color.white.opacity(0.1))
				.cornerRadius(8)
			
			if !displayValue.isEmpty {
				Text(displayValue)
					.font(.system(size: 14, weight: .medium))
					.foregroundColor(.white)
					.frame(width: 50, alignment: .trailing)
			}
		}
	}
}
