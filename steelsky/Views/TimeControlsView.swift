import SwiftUI

struct TimeControlsView: View {
	@Binding var timeOfDay: Float
	@Binding var isTimeAnimating: Bool
	@Binding var timeCycleSpeed: Float

	var body: some View {
		VStack(spacing: 16) {
			HStack {
				Text(getTimeLabel(timeOfDay))
					.font(.system(size: 18, weight: .semibold))
					.foregroundColor(.white)
				
				Spacer()
				
				Image(systemName: getSunIcon(for: timeOfDay))
					.font(.system(size: 24))
					.foregroundColor(.white)
			}
			.padding(.bottom, 5)
			
			SliderControlView(
				title: "Time of Day",
				value: $timeOfDay,
				range: 0...1,
				step: 0.01,
				displayValue: ""
			)
			
			SliderControlView(
				title: "Time Cycle Speed",
				value: $timeCycleSpeed,
				range: 0.1...5.0,
				step: 0.1,
				displayValue: String(format: "%.1f×", timeCycleSpeed)
			)
			.opacity(isTimeAnimating ? 1.0 : 0.5)
			
			Button(action: {
				isTimeAnimating.toggle()
			}) {
				HStack {
					Image(systemName: isTimeAnimating ? "pause.circle.fill" : "play.circle.fill")
						.font(.system(size: 20))
					Text(isTimeAnimating ? "Pause Time Cycle" : "Start Time Cycle")
						.font(.system(size: 16, weight: .medium))
				}
				.foregroundColor(.white)
				.padding(.vertical, 12)
				.padding(.horizontal, 20)
				.background(
					RoundedRectangle(cornerRadius: 10)
						.fill(isTimeAnimating ? Color.orange.opacity(0.8) : Color.blue.opacity(0.8))
				)
			}
			.padding(.top, 5)
		}
	}
	
	func getSunIcon(for time: Float) -> String {
		if time < 0.25 { return "moon.stars" }
		else if time < 0.45 { return "sun.horizon" }
		else if time < 0.55 { return "sun.max" }
		else if time < 0.75 { return "sun.horizon" }
		else { return "moon.stars" }
	}
	
	func getTimeLabel(_ time: Float) -> String {
		let totalHours = time * 24
		let hours = Int(totalHours)
		let totalMinutes = (totalHours - Float(hours)) * 60
		let minutes = Int(totalMinutes)
		let ampm = hours < 12 ? "AM" : "PM"
		let hour12 = hours % 12 == 0 ? 12 : hours % 12
		return String(format: "%d:%02d %@", hour12, minutes, ampm)
	}
}
