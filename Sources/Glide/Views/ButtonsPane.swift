import SwiftUI

struct ButtonsPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section {
                ActionPicker(title: "Middle button", caption: "Pressing the scroll wheel", binding: $model.settings.middleButton,
                             defaultTitle: "Default (middle click)")
                ActionPicker(title: "Back button", caption: "Lower thumb button", binding: $model.settings.backButton,
                             defaultTitle: "Default (button 4)")
                ActionPicker(title: "Forward button", caption: "Upper thumb button", binding: $model.settings.forwardButton,
                             defaultTitle: "Default (button 5)")
            } header: {
                Text("Buttons")
            } footer: {
                Footnote("Browsers understand the default back and forward buttons. Safari and Finder don't, so pick Back (⌘[) and Forward (⌘]) if you use those.")
            }

            Section {
                ActionPicker(title: "Click", caption: "Press and let go without moving", binding: $model.settings.gestureButton,
                             defaultTitle: "Nothing (the button's default)")
                Toggle(isOn: $model.settings.gesturesEnabled) {
                    Text("Hold and move for gestures")
                    Text("Hold the button and move the mouse a little in a direction. The pointer stays still while you hold it.")
                }
                if model.settings.gesturesEnabled {
                    ActionPicker(title: "Move up", binding: $model.settings.gestureUp, defaultTitle: "Nothing")
                    ActionPicker(title: "Move down", binding: $model.settings.gestureDown, defaultTitle: "Nothing")
                    ActionPicker(title: "Move left", binding: $model.settings.gestureLeft, defaultTitle: "Nothing")
                    ActionPicker(title: "Move right", binding: $model.settings.gestureRight, defaultTitle: "Nothing")
                }
            } header: {
                Text("Gesture button (under your thumb)")
            } footer: {
                if model.mouse != nil, model.mouse?.hasGestureButton == false {
                    Footnote("This mouse doesn't have a gesture button.")
                } else if model.hidStatus == .needsInputMonitoring {
                    Footnote("The gesture button needs Input Monitoring permission.", color: .orange)
                }
            }

            Section {
                ActionPicker(title: "Button behind the wheel", caption: "The small button on top", binding: $model.settings.modeShiftButton,
                             defaultTitle: "Default (ratchet / free-spin)", exclude: [.toggleWheelMode])
            } header: {
                Text("Top button")
            }
        }
        .formStyle(.grouped)
    }
}
