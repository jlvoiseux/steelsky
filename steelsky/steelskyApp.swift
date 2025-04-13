import SwiftUI
import SwiftData

@main
struct steelskyApp: App {
	var body: some Scene {
		WindowGroup {
			ContentView()
				.modelContainer(for: [GalleryItem.self])
		}
	}
}
