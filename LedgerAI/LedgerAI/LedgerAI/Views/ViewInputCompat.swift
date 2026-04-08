import SwiftUI

extension View {
    @ViewBuilder
    func platformDisableAutoInputHelpers() -> some View {
#if os(iOS)
        self
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
#else
        self
#endif
    }
}

