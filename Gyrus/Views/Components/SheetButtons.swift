import SwiftUI

/// One button in a sheet's button row.
struct SheetAction {
    var title: LocalizedStringKey
    var systemImage: String? = nil
    var isDisabled = false
    /// Replaces the title with a small spinner (and `workingTitle`, if any)
    /// while the action runs.
    var isWorking = false
    var workingTitle: LocalizedStringKey? = nil
    var perform: () -> Void

    static func cancel(isDisabled: Bool = false, _ perform: @escaping () -> Void) -> SheetAction {
        SheetAction(title: "Cancel", isDisabled: isDisabled, perform: perform)
    }
}

/// The standard trailing button row of a sheet or panel: Cancel bound to Esc
/// (`.cancelAction`) and the prominent primary button bound to Return
/// (`.defaultAction`), with optional leading content such as a status line.
///
/// Without a cancel button, Esc triggers the primary action (e.g. a lone
/// "Done"), so the sheet can still be dismissed from the keyboard.
struct SheetButtons<Accessory: View>: View {
    var cancel: SheetAction?
    var primary: SheetAction?
    private let accessory: Accessory

    init(cancel: SheetAction?, primary: SheetAction?, @ViewBuilder accessory: () -> Accessory) {
        self.cancel = cancel
        self.primary = primary
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 8) {
            accessory
            Spacer(minLength: 12)
            if let cancel {
                Button(action: cancel.perform) {
                    Text(cancel.title)
                }
                .keyboardShortcut(.cancelAction)
                .disabled(cancel.isDisabled)
            }
            if let primary {
                Button(action: primary.perform) {
                    primaryLabel(primary)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(primary.isDisabled || primary.isWorking)
            }
        }
        .background {
            if cancel == nil, let primary {
                Button("", action: primary.perform)
                    .keyboardShortcut(.cancelAction)
                    .disabled(primary.isDisabled || primary.isWorking)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder
    private func primaryLabel(_ action: SheetAction) -> some View {
        if action.isWorking {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                if let workingTitle = action.workingTitle {
                    Text(workingTitle)
                }
            }
        } else if let systemImage = action.systemImage {
            Label(action.title, systemImage: systemImage)
        } else {
            Text(action.title)
        }
    }
}

extension SheetButtons where Accessory == EmptyView {
    init(cancel: SheetAction?, primary: SheetAction?) {
        self.init(cancel: cancel, primary: primary) { EmptyView() }
    }
}
