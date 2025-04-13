import SwiftUI

struct GalleryDetailView: View {
	let item: GalleryItem
	@Environment(\.presentationMode) var presentationMode
	var onDelete: () -> Void
	var onRestore: () -> Void
	
	var body: some View {
		NavigationView {
			ScrollView {
				VStack(spacing: 20) {
					if let uiImage = UIImage(data: item.thumbnail) {
						Image(uiImage: uiImage)
							.resizable()
							.aspectRatio(contentMode: .fit)
							.cornerRadius(12)
							.shadow(radius: 5)
							.padding(.horizontal)
					}
					
					VStack(alignment: .leading, spacing: 10) {
						SettingsRow(label: "Captured on", value: formattedDate)
						SettingsRow(label: "Atmosphere", value: item.atmosphereType == 0 ? "Earth" : "Mars")
						SettingsRow(label: "Time of Day", value: formattedTime(item.timeOfDay))
						SettingsRow(label: "Fog Density", value: String(format: "%.3f", item.fogDensity))
						SettingsRow(label: "God Ray Strength", value: String(format: "%.2f", item.godRayStrength))
						SettingsRow(label: "Camera Position", value: "")
						SettingsRow(label: "   X", value: String(format: "%.1f", item.cameraPositionX))
						SettingsRow(label: "   Y", value: String(format: "%.1f", item.cameraPositionY))
						SettingsRow(label: "   Z", value: String(format: "%.1f", item.cameraPositionZ))
						SettingsRow(label: "Camera Rotation", value: "")
						SettingsRow(label: "   X", value: String(format: "%.2f°", item.cameraRotationX * 180 / Float.pi))
						SettingsRow(label: "   Y", value: String(format: "%.2f°", item.cameraRotationY * 180 / Float.pi))
					}
					.padding()
					.background(Color.black.opacity(0.3))
					.cornerRadius(12)
					.padding(.horizontal)
					
					HStack(spacing: 20) {
						Button(action: {
							onDelete()
							presentationMode.wrappedValue.dismiss()
						}) {
							Label("Delete", systemImage: "trash")
								.frame(maxWidth: .infinity)
								.padding(.vertical, 12)
								.background(Color.red.opacity(0.8))
								.foregroundColor(.white)
								.cornerRadius(10)
						}
						
						Button(action: onRestore) {
							Label("Restore", systemImage: "arrow.clockwise")
								.frame(maxWidth: .infinity)
								.padding(.vertical, 12)
								.background(Color.blue.opacity(0.8))
								.foregroundColor(.white)
								.cornerRadius(10)
						}
					}
					.padding(.horizontal)
				}
				.padding(.vertical)
			}
			.navigationTitle("Capture Details")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .navigationBarLeading) {
					Button("Back") {
						presentationMode.wrappedValue.dismiss()
					}
				}
			}
		}
	}
	
	var formattedDate: String {
		let formatter = DateFormatter()
		formatter.dateStyle = .medium
		formatter.timeStyle = .short
		return formatter.string(from: item.timestamp)
	}
	
	func formattedTime(_ time: Float) -> String {
		let totalHours = time * 24
		let hours = Int(totalHours)
		let totalMinutes = (totalHours - Float(hours)) * 60
		let minutes = Int(totalMinutes)
		let ampm = hours < 12 ? "AM" : "PM"
		let hour12 = hours % 12 == 0 ? 12 : hours % 12
		return String(format: "%d:%02d %@", hour12, minutes, ampm)
	}
}

struct SettingsRow: View {
	var label: String
	var value: String
	
	var body: some View {
		HStack {
			Text(label)
				.foregroundColor(.gray)
				.font(.system(size: 16))
			Spacer()
			Text(value)
				.foregroundColor(.white)
				.font(.system(size: 16, weight: .medium))
		}
	}
}
