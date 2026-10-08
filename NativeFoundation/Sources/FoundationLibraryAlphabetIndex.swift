#if os(iOS)
    import SwiftUI
    import UIKit

    /// Loaded sections share the full catalog membership and its scroll anchors.
    struct FoundationAlphabetSection: Identifiable, Equatable {
        enum Availability: Equatable { case notLoaded, loading, loaded, unavailableOffline }
        let id: String
        let title: String
        let availability: Availability
        var rows: [FoundationAlphabetRow]
    }

    /// Occurrence identity must survive cell reuse without matching another canonical item.
    struct FoundationAlphabetRow: Identifiable, Equatable {
        let id: String
        let item: FoundationItem
    }

    /// Native rows retain normal scrolling while the adjacent rail selects loaded anchors.
    struct FoundationLibraryAlphabetIndex<Row: View>: UIViewRepresentable {
        let contextID: String
        let sections: [FoundationAlphabetSection]
        var columnCount = 1
        var isCoverGrid = false
        var rowHeight: CGFloat = 72
        var allowsDemand = false
        var isRefreshing = false
        var nextPageIdentity: String?
        var anchorRowID: String?
        var anchorRevision = 0
        let onDemandNextPage: () -> Void
        let onRefresh: () -> Void
        @ViewBuilder let row: (FoundationAlphabetRow) -> Row

        func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

        func makeUIView(context: Context) -> UITableView {
            makeTable(coordinator: context.coordinator)
        }

        func makeTable(coordinator: Coordinator) -> UITableView {
            let table = UITableView(frame: .zero, style: .plain)
            table.dataSource = coordinator
            table.delegate = coordinator
            table.rowHeight = isCoverGrid ? UITableView.automaticDimension : rowHeight
            // Songs have fixed metrics. Estimates and hosted self-sizing can move a distant
            // anchor again when previously offscreen cells settle after the rail is released.
            table.estimatedRowHeight = isCoverGrid ? rowHeight : 0
            table.selfSizingInvalidation = isCoverGrid ? .enabled : .disabled
            table.sectionHeaderHeight = 28
            table.estimatedSectionHeaderHeight = 0
            table.sectionFooterHeight = 0
            table.estimatedSectionFooterHeight = 0
            table.sectionHeaderTopPadding = 0
            table.separatorStyle = isCoverGrid ? .none : .singleLine
            table.register(UITableViewCell.self, forCellReuseIdentifier: "catalog-row")
            let refresh = UIRefreshControl()
            refresh.addTarget(
                coordinator, action: #selector(Coordinator.refreshRequested),
                for: .valueChanged)
            table.refreshControl = refresh
            return table
        }

        func updateUIView(_ table: UITableView, context: Context) {
            updateTable(table, coordinator: context.coordinator)
        }

        func updateTable(_ table: UITableView, coordinator: Coordinator) {
            let contextChanged = coordinator.parent.contextID != contextID
            let layoutChanged =
                coordinator.parent.columnCount != columnCount
                || coordinator.parent.isCoverGrid != isCoverGrid
                || coordinator.parent.rowHeight != rowHeight
            if contextChanged || (!coordinator.parent.allowsDemand && allowsDemand) {
                coordinator.lastDemandIdentity = nil
            }
            let visibleAnchor = contextChanged ? nil : coordinator.visibleAnchor(in: table)
            coordinator.parent = self
            // Snapshot changes are explicit; the table never discovers/fetches another letter.
            table.separatorStyle = isCoverGrid ? .none : .singleLine
            table.rowHeight = isCoverGrid ? UITableView.automaticDimension : rowHeight
            // Songs have fixed metrics. Estimates and hosted self-sizing can move a distant
            // anchor again when previously offscreen cells settle after the rail is released.
            table.estimatedRowHeight = isCoverGrid ? rowHeight : 0
            table.selfSizingInvalidation = isCoverGrid ? .enabled : .disabled
            if contextChanged || layoutChanged || coordinator.snapshot != sections {
                coordinator.snapshot = sections
                coordinator.geometryRevision += 1
                table.reloadData()
                table.layoutIfNeeded()
                if coordinator.appliedAnchorRevision == anchorRevision, let visibleAnchor {
                    coordinator.restoreVisibleAnchor(visibleAnchor, in: table)
                }
            }
            if coordinator.appliedAnchorRevision != anchorRevision {
                coordinator.appliedAnchorRevision = anchorRevision
                coordinator.scrollToAnchor(in: table)
            }
            coordinator.checkVisibleDemandAfterLayout(in: table)
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
            var lastDemandIdentity: String?
            var geometryRevision = 0
            var appliedAnchorRevision = 0

            init(parent: FoundationLibraryAlphabetIndex) { self.parent = parent }

            func numberOfSections(in tableView: UITableView) -> Int { parent.sections.count }

            func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
                FoundationLibraryGridLayout.rowCount(
                    itemCount: parent.sections[section].rows.count, columns: parent.columnCount)
            }

            func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath)
                -> UITableViewCell
            {
                let columns = max(1, parent.columnCount)
                let sectionRows = parent.sections[indexPath.section].rows
                let range = FoundationLibraryGridLayout.itemRange(
                    row: indexPath.row, itemCount: sectionRows.count, columns: columns)
                let entries = Array(sectionRows[range])
                let cell = tableView.dequeueReusableCell(
                    withIdentifier: "catalog-row", for: indexPath)
                // The caller injects existing account-owned environments, source namespace,
                // and canonical row callbacks; this adapter creates no second transition owner.
                cell.contentConfiguration = UIHostingConfiguration {
                    HStack(alignment: .top, spacing: self.parent.isCoverGrid ? 18 : 0) {
                        ForEach(entries) { entry in
                            self.parent.row(entry).id(entry.id)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                        ForEach(entries.count..<columns, id: \.self) { _ in
                            Color.clear.frame(maxWidth: .infinity).accessibilityHidden(true)
                        }
                    }
                }.margins(.vertical, parent.isCoverGrid ? 11 : 4)
                cell.selectionStyle = .none
                return cell
            }

            func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView?
            {
                let header = UITableViewHeaderFooterView()
                var content = header.defaultContentConfiguration()
                content.text = parent.sections[section].title
                content.textProperties.font = .preferredFont(forTextStyle: .caption1)
                content.textProperties.color = .secondaryLabel
                header.contentConfiguration = content
                header.accessibilityIdentifier =
                    "library-letter-section-" + parent.sections[section].title
                return header
            }

            struct VisibleAnchor {
                let rowID: String
                let offsetFromTop: CGFloat
            }

            func visibleAnchor(in table: UITableView) -> VisibleAnchor? {
                // Ignore the previous row hidden behind the pinned section header.
                let visibleTop =
                    table.contentOffset.y + table.adjustedContentInset.top
                    + table.sectionHeaderHeight
                guard
                    let path = table.indexPathsForVisibleRows?.sorted().first(where: {
                        table.rectForRow(at: $0).maxY > visibleTop
                    }), parent.sections.indices.contains(path.section)
                else { return nil }
                let rows = parent.sections[path.section].rows
                let index = path.row * max(1, parent.columnCount)
                guard rows.indices.contains(index) else { return nil }
                return VisibleAnchor(
                    rowID: rows[index].id,
                    offsetFromTop: table.rectForRow(at: path).minY - table.contentOffset.y)
            }

            func restoreVisibleAnchor(_ anchor: VisibleAnchor, in table: UITableView) {
                // New pages can sort before the visible section. Preserve the row and its
                // on-screen position rather than leaving the same offset on different songs.
                for (section, value) in parent.sections.enumerated() {
                    guard let row = value.rows.firstIndex(where: { $0.id == anchor.rowID }) else {
                        continue
                    }
                    let path = IndexPath(row: row / max(1, parent.columnCount), section: section)
                    let minimum = -table.adjustedContentInset.top
                    let maximum = max(
                        minimum,
                        table.contentSize.height - table.bounds.height
                            + table.adjustedContentInset.bottom)
                    let offset = min(
                        maximum,
                        max(minimum, table.rectForRow(at: path).minY - anchor.offsetFromTop))
                    table.setContentOffset(
                        CGPoint(x: table.contentOffset.x, y: offset), animated: false)
                    return
                }
            }

            func scrollToAnchor(in table: UITableView) {
                guard let target = parent.anchorRowID else { return }
                let contextID = parent.contextID
                let request = parent.anchorRevision
                // Coalesce layout work; a newer scrub revokes this scroll.
                DispatchQueue.main.async { [weak self, weak table] in
                    guard let self, let table, table.delegate === self,
                        self.parent.contextID == contextID, self.parent.anchorRevision == request,
                        self.parent.anchorRowID == target
                    else { return }
                    for (section, value) in self.parent.sections.enumerated() {
                        if let row = value.rows.firstIndex(where: { $0.id == target }) {
                            table.layoutIfNeeded()
                            table.scrollToRow(
                                at: IndexPath(
                                    row: row / max(1, self.parent.columnCount), section: section),
                                at: .top, animated: false)
                            return
                        }
                    }
                }
            }

            func tableView(
                _ tableView: UITableView, willDisplay cell: UITableViewCell,
                forRowAt indexPath: IndexPath
            ) {
                checkDemandAfterLayout(in: tableView, cell: cell, indexPath: indexPath)
            }

            func scrollViewDidScroll(_ scrollView: UIScrollView) {
                guard let table = scrollView as? UITableView else { return }
                checkVisibleDemandAfterLayout(in: table)
            }

            func checkVisibleDemandAfterLayout(in table: UITableView) {
                for indexPath in table.indexPathsForVisibleRows ?? [] {
                    if let cell = table.cellForRow(at: indexPath) {
                        checkDemandAfterLayout(in: table, cell: cell, indexPath: indexPath)
                    }
                }
            }

            private func checkDemandAfterLayout(
                in table: UITableView, cell: UITableViewCell, indexPath: IndexPath
            ) {
                guard parent.allowsDemand, let identity = parent.nextPageIdentity,
                    lastDemandIdentity != identity,
                    let finalSection = parent.sections.lastIndex(where: { !$0.rows.isEmpty }),
                    indexPath.section == finalSection,
                    indexPath.row >= max(0, table.numberOfRows(inSection: finalSection) - 3)
                else { return }
                let contextID = parent.contextID
                let revision = geometryRevision
                // willDisplay can describe estimated/offscreen hosted cells during reload or AX
                // enumeration. One main turn lets self-sizing settle; no callback owns a fetch.
                DispatchQueue.main.async { [weak self, weak table, weak cell] in
                    guard let self, let table, let cell,
                        self.parent.contextID == contextID, self.geometryRevision == revision,
                        self.parent.allowsDemand, self.parent.nextPageIdentity == identity,
                        self.lastDemandIdentity != identity,
                        table.delegate === self,
                        let window = table.window, !window.isHidden, cell.window === window,
                        table.bounds.width > 0, table.bounds.height > 0,
                        table.cellForRow(at: indexPath) === cell,
                        table.indexPathsForVisibleRows?.contains(indexPath) == true,
                        let finalSection = self.parent.sections.lastIndex(where: {
                            !$0.rows.isEmpty
                        }),
                        indexPath.section == finalSection,
                        indexPath.row >= max(0, table.numberOfRows(inSection: finalSection) - 3)
                    else { return }
                    let viewport = table.bounds.inset(by: table.adjustedContentInset)
                    let rowFrame = table.rectForRow(at: indexPath)
                    let cellFrame = cell.convert(cell.bounds, to: table)
                    guard !viewport.isEmpty, !rowFrame.isEmpty, !cellFrame.isEmpty,
                        rowFrame.intersection(viewport).height > 1,
                        cellFrame.intersection(viewport).height > 1,
                        cellFrame.intersection(viewport).width > 1
                    else { return }
                    self.lastDemandIdentity = identity
                    // The caller retains active/offline/loading/error/end and cancellation guards.
                    self.parent.onDemandNextPage()
                }
            }

            @objc func refreshRequested() { parent.onRefresh() }
        }
    }

#endif
