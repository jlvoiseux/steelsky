import SwiftUI

struct TabButtonView: View {
	var title: String
	var isSelected: Bool
	var action: () -> Void
	
	var body: some View {
		Button(action: action) {
			Text(title)
				.font(.system(size: 14, weight: isSelected ? .semibold : .medium))
				.foregroundColor(isSelected ? .white : .gray)
				.padding(.vertical, 8)
				.padding(.horizontal, 12)
				.background(
					isSelected ?
					RoundedRectangle(cornerRadius: 8)
						.fill(Color.blue.opacity(0.7)) :
					RoundedRectangle(cornerRadius: 8)
						.fill(Color.clear)
				)
		}
		.frame(maxWidth: .infinity)
	}
}
