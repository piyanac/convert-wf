import SwiftUI

struct ContentView: View {
    @StateObject private var store = ConversionWorkflowStore()

    var body: some View {
        WorkflowShellView(store: store)
            .background(Color(nsColor: .windowBackgroundColor))
            .frame(width: store.windowWidth, height: store.windowHeight)
            .navigationTitle(toolbarTitle)
            .toolbarRole(.editor)
            .toolbar {
                if store.currentStep != .source {
                    ToolbarItem(placement: .navigation) {
                        Button(action: store.goToPreviousStep) {
                            Image(systemName: "chevron.left")
                        }
                        .disabled(store.currentStep == .progress)
                    }
                }
            }
            .alert("alert.action_failed.title", isPresented: Binding(
                get: { store.fileActionErrorMessage != nil },
                set: { newValue in
                    if !newValue {
                        store.fileActionErrorMessage = nil
                    }
                }
            )) {
                Button("common.ok") {
                    store.fileActionErrorMessage = nil
                }
            } message: {
                Text(store.fileActionErrorMessage ?? "")
            }
    }

    private var toolbarTitle: String {
        switch store.currentStep {
        case .source:
            return ""
        case .files:
            return L10n.tr("toolbar.step.files")
        case .config:
            return L10n.tr("toolbar.step.config")
        case .progress:
            return L10n.tr("toolbar.step.converting")
        case .result:
            return L10n.tr("toolbar.step.result")
        }
    }
}

#Preview {
    ContentView()
}
