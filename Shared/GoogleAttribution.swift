import SwiftUI

/// The Google Maps mark that Google requires under a list of its results shown without a Google map.
/// The image is the official logo, unmodified: Gray in the light appearance, White in the dark appearance.
struct GoogleMapsAttribution: View {
    static let height: CGFloat = 18
    static let clearSpace = EdgeInsets(top: 10, leading: 10, bottom: 5, trailing: 10)

    var body: some View {
        Image("GoogleMapsLogo")
            .resizable()
            .scaledToFit()
            .frame(height: Self.height)
            .accessibilityLabel("Google Maps")
            .padding(Self.clearSpace)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
