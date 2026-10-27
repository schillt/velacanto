import SwiftUI

struct FoundationPinSyncSection: View {
    @ObservedObject var sync: FoundationPinSync
    @State private var confirmsDeletion = false

    var body: some View {
        Section {
            Toggle(
                "Sync Pins with iCloud",
                isOn: Binding(
                    get: { sync.enabled }, set: { sync.setEnabled($0) })
            )
            .disabled(!sync.available)
            Text(sync.message).font(.footnote).foregroundStyle(.secondary)
            if sync.enabled {
                Button("Sync Now") { sync.refresh() }.disabled(sync.isSyncing)
                Button("Delete Cloud-Saved Pins", role: .destructive) {
                    confirmsDeletion = true
                }
                .disabled(sync.isSyncing)
                .confirmationDialog(
                    "Delete cloud-saved pins for this library?", isPresented: $confirmsDeletion,
                    titleVisibility: .visible
                ) {
                    Button("Delete Cloud-Saved Pins", role: .destructive) { sync.deleteCloudPins() }
                } message: {
                    Text(
                        "Local pins on this device are kept. Other enabled devices remove these pins on their next sync. Old offline edits cannot restore them. This cannot be undone."
                    )
                }
            }
        } header: {
            Text("iCloud Pins")
        } footer: {
            Text(
                "Only pin identities and order sync for this server and account. Turning sync off or signing out keeps cloud pins in iCloud. Use Delete Cloud-Saved Pins to remove them separately."
            )
        }
    }
}
