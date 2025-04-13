import SwiftUI
import SwiftData

struct GalleryView: View {
	var galleryItems: [GalleryItem]
	var galleryViewModel: GalleryViewModel
	@Environment(\.presentationMode) var presentationMode
	@State private var selectedItem: GalleryItem?
	
	var onRestoreState: (GalleryItem) -> Void
	
	let columns = [
		GridItem(.adaptive(minimum: 120), spacing: 10)
	]
	
	var body: some View {
		NavigationView {
			ScrollView {
				LazyVGrid(columns: columns, spacing: 10) {
					ForEach(galleryItems) { item in
						GalleryItemView(item: item)
							.onTapGesture {
								selectedItem = item
							}
					}
				}
				.padding()
			}
			.navigationTitle("Gallery")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .navigationBarLeading) {
					Button("Close") {
						presentationMode.wrappedValue.dismiss()
					}
				}
			}
			.sheet(item: $selectedItem) { item in
				GalleryDetailView(
					item: item,
					onDelete: {
						deleteItem(item)
					},
					onRestore: {
						onRestoreState(item)
						presentationMode.wrappedValue.dismiss()
					}
				)
			}
		}
	}
	
	private func deleteItem(_ item: GalleryItem) {
		// Use the ViewModel to handle database operations
		galleryViewModel.deleteItem(item)
		selectedItem = nil
	}
}

struct GalleryItemView: View {
	let item: GalleryItem
	
	var body: some View {
		VStack {
			if let uiImage = UIImage(data: item.thumbnail) {
				Image(uiImage: uiImage)
					.resizable()
					.aspectRatio(contentMode: .fill)
					.frame(width: 120, height: 120)
					.cornerRadius(8)
					.clipped()
			} else {
				Rectangle()
					.fill(Color.gray)
					.frame(width: 120, height: 120)
					.cornerRadius(8)
			}
			
			Text(formattedDate)
				.font(.system(size: 12))
				.foregroundColor(.white)
		}
	}
	
	var formattedDate: String {
		let formatter = DateFormatter()
		formatter.dateStyle = .short
		formatter.timeStyle = .short
		return formatter.string(from: item.timestamp)
	}
}
