#if os(iOS)
    import SwiftUI
    import UIKit

    /// A real native index selection can request an unloaded section. The caller owns its data.
    struct FoundationAlphabetSection: Identifiable, Equatable {
        enum Availability: Equatable { case notLoaded, loading, loaded, unavailableOffline }
        let id: String
        let title: String
        let availability: Availability
        let rows: [FoundationAlphabetRow]
    }

    /// Occurrence identity must survive cell reuse without matching another canonical item.
    struct FoundationAlphabetRow: Identifiable, Equatable {
        let id: String
        let item: FoundationItem
    }

    /// Opt-in prototype: it does not replace the current SwiftUI index or its navigation owner.
    struct FoundationLibraryAlphabetIndex<Row: View>: UIViewRepresentable {
        let contextID: String
        let sections: [FoundationAlphabetSection]
        let indexTitles: [String]
        var allowsDemand = false
        var isRefreshing = false
        var nextPageIdentity: String?
        let onChooseLetter: (String) -> Void
        let onDemandNextPage: () -> Void
        let onRefresh: () -> Void
        @ViewBuilder let row: (FoundationAlphabetRow) -> Row

        func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

        func makeUIView(context: Context) -> UITableView {
            let table = UITableView(frame: .zero, style: .plain)
            table.dataSource = context.coordinator
            table.delegate = context.coordinator
            table.rowHeight = UITableView.automaticDimension
            table.estimatedRowHeight = 72
            table.sectionHeaderHeight = UITableView.automaticDimension
            table.estimatedSectionHeaderHeight = 32
            table.sectionIndexMinimumDisplayRowCount = 0
            table.register(UITableViewCell.self, forCellReuseIdentifier: "catalog-row")
            let refresh = UIRefreshControl()
            refresh.addTarget(
                context.coordinator, action: #selector(Coordinator.refreshRequested),
                for: .valueChanged)
            table.refreshControl = refresh
            return table
        }

        func updateUIView(_ table: UITableView, context: Context) {
            let coordinator = context.coordinator
            let contextChanged = coordinator.parent.contextID != contextID
            if contextChanged { coordinator.lastDemandIdentity = nil }
            coordinator.parent = self
            // Snapshot changes are explicit; the table never discovers/fetches another letter.
            if contextChanged || coordinator.snapshot != sections
                || coordinator.indexSnapshot != indexTitles
            {
                coordinator.snapshot = sections
                coordinator.indexSnapshot = indexTitles
                table.reloadData()
            }
            if !isRefreshing { table.refreshControl?.endRefreshing() }
        }

        static func dismantleUIView(_ table: UITableView, coordinator: Coordinator) {
            table.refreshControl?.endRefreshing()
            table.dataSource = nil
            table.delegate = nil
        }

        @MainActor
        final class Coordinator: NSObject, UITableViewDataSource, UITableViewDelegate {
            var parent: FoundationLibraryAlphabetIndex
            var snapshot: [FoundationAlphabetSection] = []
            var indexSnapshot: [String] = []
            var lastDemandIdentity: String?

            init(parent: FoundationLibraryAlphabetIndex) { self.parent = parent }

            func numberOfSections(in tableView: UITableView) -> Int { parent.sections.count }

            func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
                parent.sections[section].rows.count
            }

            func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath)
                -> UITableViewCell
            {
                let entry = parent.sections[indexPath.section].rows[indexPath.row]
                let cell = tableView.dequeueReusableCell(
                    withIdentifier: "catalog-row", for: indexPath)
                // The caller injects existing account-owned environments, source namespace,
                // and canonical row callbacks; this adapter creates no second transition owner.
                cell.contentConfiguration = UIHostingConfiguration {
                    self.parent.row(entry).id(entry.id)
                }.margins(.vertical, 4)
                cell.selectionStyle = .none
                return cell
            }

            func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int)
                -> String?
            {
                let value = parent.sections[section]
                switch value.availability {
                case .notLoaded: return value.title + " — Not loaded"
                case .loading: return value.title + " — Loading"
                case .loaded: return value.title
                case .unavailableOffline: return value.title + " — Unavailable offline"
                }
            }

            func sectionIndexTitles(for tableView: UITableView) -> [String]? {
                parent.sections.isEmpty || parent.indexTitles.isEmpty ? nil : parent.indexTitles
            }

            func tableView(
                _ tableView: UITableView, sectionForSectionIndexTitle title: String, at index: Int
            ) -> Int {
                // UIKit invokes this for a genuine native scrub/tap, even before rows arrive.
                // Do not block its synchronous mapping callback on an asynchronous provider load.
                parent.onChooseLetter(title)
                return parent.sections.firstIndex { $0.id == title } ?? 0
            }

            func tableView(
                _ tableView: UITableView, willDisplay cell: UITableViewCell,
                forRowAt indexPath: IndexPath
            ) {
                guard parent.allowsDemand, let identity = parent.nextPageIdentity,
                    lastDemandIdentity != identity,
                    let finalSection = parent.sections.lastIndex(where: { !$0.rows.isEmpty }),
                    indexPath.section == finalSection,
                    indexPath.row >= max(0, parent.sections[finalSection].rows.count - 3)
                else { return }
                lastDemandIdentity = identity
                // The caller still applies active/offline/loading/error/end cursor guards.
                parent.onDemandNextPage()
            }

            @objc func refreshRequested() { parent.onRefresh() }
        }
    }

#endif
