import SwiftUI
import SwiftData

@Model
final class GalleryItem {
	var id = UUID()
	var timestamp: Date
	var thumbnail: Data
	var cameraPositionX: Float
	var cameraPositionY: Float
	var cameraPositionZ: Float
	var cameraRotationX: Float
	var cameraRotationY: Float
	var atmosphereType: Int
	var timeOfDay: Float
	var fogDensity: Float
	var godRayStrength: Float
	var movementSpeed: Float
	var timeCycleSpeed: Float
	
	init(timestamp: Date,
		 thumbnail: Data,
		 cameraPositionX: Float,
		 cameraPositionY: Float,
		 cameraPositionZ: Float,
		 cameraRotationX: Float,
		 cameraRotationY: Float,
		 atmosphereType: Int,
		 timeOfDay: Float,
		 fogDensity: Float,
		 godRayStrength: Float,
		 movementSpeed: Float,
		 timeCycleSpeed: Float) {
		
		self.timestamp = timestamp
		self.thumbnail = thumbnail
		self.cameraPositionX = cameraPositionX
		self.cameraPositionY = cameraPositionY
		self.cameraPositionZ = cameraPositionZ
		self.cameraRotationX = cameraRotationX
		self.cameraRotationY = cameraRotationY
		self.atmosphereType = atmosphereType
		self.timeOfDay = timeOfDay
		self.fogDensity = fogDensity
		self.godRayStrength = godRayStrength
		self.movementSpeed = movementSpeed
		self.timeCycleSpeed = timeCycleSpeed
	}
}
