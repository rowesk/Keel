import SwiftUI

/// The queue expands only on click or keyboard activation. Its collapsed line
/// names the next destination and keeps recovery separate from moving forward.
struct HomeQueueView: View {
    private enum FocusTarget: Hashable {
        case list
        case primary
        case undoDeletion
        case deleteSelection
        case clearQueue
    }

    /// One row of the sheet, in the order the sheet shows them.
    private enum Entry: Hashable {
        case resume
        case undo
        case queued(UUID)
    }

    let model: KeelHomeModel
    let actions: KeelHomeActions
    /// The room between the status line and the bottom edge. The sheet never
    /// rises past it; rows scroll inside instead.
    let maxHeight: CGFloat
    @State private var interactionState = KeelHomeInteractionState()
    @State private var isShowingConfirmation = false
    @State private var hoveredID: UUID?
    @State private var isOpen: Bool

    init(model: KeelHomeModel, actions: KeelHomeActions, maxHeight: CGFloat, initiallyExpanded: Bool = false) {
        self.model = model
        self.actions = actions
        self.maxHeight = maxHeight
        _isOpen = State(initialValue: initiallyExpanded)
    }
    @Environment(\.keelFixedNow) private var fixedNow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedControl: FocusTarget?

    // MARK: Geometry

    static let lineHeight: CGFloat = 44
    static let rowHeight: CGFloat = 44
    static let footerHeight: CGFloat = 36
    /// Space between the line and the bottom edge of the window.
    static let bottomMargin: CGFloat = 28

    private var entries: [Entry] {
        var list: [Entry] = []
        if model.resume != nil { list.append(.resume) }
        if model.undo != nil { list.append(.undo) }
        list.append(contentsOf: model.queue.map { .queued($0.id) })
        return list
    }

    private var hasFooter: Bool { model.queue.count > 1 }

    private var contentHeight: CGFloat {
        CGFloat(entries.count) * Self.rowHeight + (hasFooter ? Self.footerHeight : 0)
    }

    private var rowsHeight: CGFloat {
        guard isOpen else { return 0 }
        let room = maxHeight - Self.lineHeight - Self.bottomMargin
        // Whole rows only, so the cut never lands mid-row.
        let wholeRows = floor(max(0, room) / Self.rowHeight) * Self.rowHeight
        return max(Self.rowHeight, min(contentHeight, wholeRows))
    }

    private var scrolls: Bool { contentHeight > rowsHeight }

    var body: some View {
        VStack(spacing: 0) {
            if isOpen {
                sheetRows
                    .frame(height: rowsHeight)
                    .transition(.opacity)
                KeelRowSeparator(leadingInset: 0)
            }
            line
                .frame(height: Self.lineHeight)
        }
        .background(
            RoundedRectangle(cornerRadius: KeelDesign.Radius.card)
                .fill(isOpen ? KeelDesign.Surface.raised : Color(red: 0.10, green: 0.12, blue: 0.08).opacity(0.78))
                .shadow(color: .black.opacity(isOpen ? 0.12 : 0), radius: 2, y: 1)
                .shadow(color: .black.opacity(isOpen ? 0.28 : 0), radius: 28, y: 12)
        )
        .overlay(
            RoundedRectangle(cornerRadius: KeelDesign.Radius.card)
                .strokeBorder(KeelDesign.Surface.hairline.opacity(isOpen ? 1 : 0), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: KeelDesign.Radius.card))
        .padding(.bottom, Self.bottomMargin)
        .animation(reduceMotion ? nil : sheetAnimation, value: isOpen)
        .animation(reduceMotion ? nil : sheetAnimation, value: entries)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Queue, first in first out")
        .confirmationDialog(
            interactionState.pendingDeletion?.confirmationTitle ?? "Confirm queue deletion",
            isPresented: $isShowingConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                confirmPendingDeletion()
            }
            Button("Cancel", role: .cancel) {
                interactionState.cancelPendingDeletion()
                isShowingConfirmation = false
            }
        } message: {
            Text(interactionState.pendingDeletion?.confirmationMessage ?? "")
        }
        .onChange(of: model.visibleQueueIDs) { _, queueIDs in
            interactionState.pruneSelection(to: Set(queueIDs))
        }
        .onChange(of: entries.isEmpty) { _, empty in
            if empty { setOpen(false) }
        }
        .onExitCommand {
            if interactionState.pendingDeletion != nil || !interactionState.selectedQueueIDs.isEmpty {
                _ = interactionState.handle(.escape, queueIDs: model.visibleQueueIDs)
                isShowingConfirmation = interactionState.pendingDeletion != nil
            } else {
                setOpen(false)
            }
        }
    }

    private var sheetAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.15) : KeelDesign.Motion.queueChange
    }

    private func setOpen(_ open: Bool) {
        guard open != isOpen else { return }
        withAnimation(reduceMotion ? nil : sheetAnimation) {
            isOpen = open
        }

    }

    // MARK: The line

    /// What the line names: the first thing the sheet would show.
    private var lead: (caption: String, title: String)? {
        if let resume = model.resume { return ("Unfinished", resume.primaryText) }
        if let next = model.queue.first { return ("Up next", next.primaryText) }
        if let undo = model.undo { return ("Recently closed", undo.primaryText) }
        if model.queueDeletionUndo != nil { return ("Queue", "Removed") }
        return nil
    }

    private var moreText: String? {
        model.queueCountDescription
    }

    private var lineTone: Color {
        isOpen ? KeelDesign.Surface.ink : KeelDesign.Surface.scrimText
    }

    private var lineSecondaryTone: Color {
        isOpen ? KeelDesign.Surface.inkSecondary : KeelDesign.Surface.scrimText.opacity(0.95)
    }

    @ViewBuilder
    private var line: some View {
        if let lead {
            HStack(spacing: KeelDesign.Space.snug) {
                Text(lead.caption.uppercased())
                    .font(KeelDesign.Text.smallCaps)
                    .tracking(KeelDesign.Text.smallCapsTracking)
                    .foregroundStyle(lineSecondaryTone)
                    .padding(.trailing, 2)

                Text(lead.title)
                    .font(KeelDesign.Text.rowTitle)
                    .foregroundStyle(lineTone)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let moreText {
                    Text(moreText)
                        .font(KeelDesign.Text.body)
                        .foregroundStyle(lineSecondaryTone)
                        .lineLimit(1)
                        .layoutPriority(1)
                }

                Spacer(minLength: KeelDesign.Space.regular)

                // No ticking clock here. The Store still expires the undo on
                // its own; the affordance simply fades when that happens.
                if let undo = model.queueDeletionUndo {
                    Button(undo.deletedCount == 1 ? "Undo removal" : "Undo \(undo.deletedCount) removed") {
                        actions.perform(.restoreQueueDeletionUndo)
                    }
                    .buttonStyle(KeelLinkButtonStyle(color: lineSecondaryTone))
                    .focused($focusedControl, equals: .undoDeletion)
                    .transition(.opacity)
                }

                if !interactionState.selectedQueueIDs.isEmpty {
                    Button("Remove \(interactionState.selectedQueueIDs.count) selected") {
                        requestSelectedDeletion()
                    }
                    .buttonStyle(KeelLinkButtonStyle(color: lineSecondaryTone))
                    .focused($focusedControl, equals: .deleteSelection)
                }

                if model.undo != nil && model.hasVisibleQueue && model.resume == nil {
                    Button("Undo close") { actions.perform(.restoreClosedPage) }
                        .buttonStyle(KeelLinkButtonStyle(color: lineSecondaryTone))
                }
                primaryButton

                Button {
                    setOpen(!isOpen)
                } label: {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.up")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(lineSecondaryTone)

                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isOpen ? "Collapse queue" : "Expand queue")
                .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
            }
            .padding(.leading, KeelDesign.Space.regular)
            .padding(.trailing, KeelDesign.Space.tight)
            .shadow(color: .black.opacity(isOpen ? 0 : 0.4), radius: 6, y: 1)
            .contentShape(Rectangle())
            .onTapGesture {
                setOpen(!isOpen)
            }
            .animation(KeelDesign.Motion.stateChange, value: model.queueDeletionUndo?.deadline)
            .animation(KeelDesign.Motion.stateChange, value: interactionState.selectedQueueIDs)
        }
    }

    /// The verb for whatever the line names. Start carries its shortcut; the
    /// others are one click and say so by having none.
    @ViewBuilder
    private var primaryButton: some View {
        let tone: KeelOutlineButtonStyle.Tone = isOpen ? .ink : .scrim
        if model.primaryAction == .resume {
            Button("Resume") { actions.perform(.resume) }
                .buttonStyle(KeelOutlineButtonStyle(tone: tone))
                .focused($focusedControl, equals: .primary)
        } else if model.primaryAction == .startQueue {
            Button("Start") { actions.perform(.startQueue) }
                .buttonStyle(KeelOutlineButtonStyle(tone: tone, hint: "⌘↩"))
                .disabled(!model.canStartQueue)
                .opacity(model.canStartQueue ? 1 : 0.45)
                .focused($focusedControl, equals: .primary)
                .help(model.startBlockedReason ?? "Open the oldest queued destination  ⌘↩")
        } else if model.primaryAction == .restoreClosedPage {
            Button("Reopen") { actions.perform(.restoreClosedPage) }
                .buttonStyle(KeelOutlineButtonStyle(tone: tone))
                .focused($focusedControl, equals: .primary)

        }
    }

    // MARK: The sheet

    private var sheetRows: some View {
        ScrollView {
            VStack(spacing: 0) {
                if let resume = model.resume {
                    resumeRow(resume)
                }
                if let undo = model.undo {
                    undoRow(undo)
                }
                ForEach(Array(model.queue.enumerated()), id: \.element.id) { index, item in
                    queueRow(item, position: index + 1)
                        .transition(rowTransition)
                }
                if hasFooter {
                    HStack {
                        Spacer(minLength: 0)
                        Button("Clear queue") {
                            requestClearQueue()
                        }
                        .buttonStyle(KeelLinkButtonStyle())
                        .focused($focusedControl, equals: .clearQueue)
                        Spacer(minLength: 0)
                    }
                    .frame(height: Self.footerHeight)
                }
            }
            .animation(reduceMotion ? nil : sheetAnimation, value: model.visibleQueueIDs)
        }
        .scrollIndicators(.automatic)
        .scrollBounceBehavior(.basedOnSize)
        .mask(
            // A quiet edge, not a hard cut, where more rows continue below.
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: scrolls ? 0.88 : 1),
                    .init(color: .black.opacity(scrolls ? 0 : 1), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .focused($focusedControl, equals: .list)
        .focusable()
        .onMoveCommand { direction in
            let key: KeelHomeKey?
            switch direction {
            case .up: key = .moveUp
            case .down: key = .moveDown
            default: key = nil
            }
            if let key {
                _ = interactionState.handle(key, queueIDs: model.visibleQueueIDs)
            }
        }
        .onDeleteCommand {
            requestSelectedDeletion()
        }
    }

    private var rowTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .opacity.combined(with: .offset(y: -4)),
                removal: .opacity
            )
    }

    private func resumeRow(_ item: KeelResumeItem) -> some View {
        HStack(spacing: KeelDesign.Space.snug) {
            Color.clear.frame(width: 16)
            KeelFaviconView(icon: item.icon, size: 16, monogramSource: item.secondaryText)
            Text(item.primaryText)
                .font(KeelDesign.Text.rowTitle)
                .foregroundStyle(KeelDesign.Surface.ink)
                .lineLimit(1)
            Text("Unfinished · left \(item.savedAt.keelRelativeDescription(from: fixedNow ?? .now))")
                .font(KeelDesign.Text.detail)
                .foregroundStyle(KeelDesign.Surface.inkSecondary)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: KeelDesign.Space.snug)
            Button("Discard") { actions.perform(.discardResume) }
                .buttonStyle(KeelLinkButtonStyle())
        }
        .padding(.horizontal, KeelDesign.Inset.card)
        .frame(height: Self.rowHeight)
        .background(KeelDesign.Surface.accent.opacity(0.08))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Unfinished page. \(item.accessibilitySummary)")
    }

    private func undoRow(_ item: KeelUndoItem) -> some View {
        HStack(spacing: KeelDesign.Space.snug) {
            Color.clear.frame(width: 16)
            KeelFaviconView(icon: item.icon, size: 16, monogramSource: item.secondaryText)
            Text(item.primaryText)
                .font(KeelDesign.Text.rowTitle)
                .foregroundStyle(KeelDesign.Surface.ink)
                .lineLimit(1)
            Text("Closed · kept until \(item.deadline.formatted(date: .omitted, time: .shortened))")
                .font(KeelDesign.Text.detail)
                .foregroundStyle(KeelDesign.Surface.inkSecondary)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: KeelDesign.Space.snug)
            Button("Discard") { actions.perform(.discardClosedPage) }
                .buttonStyle(KeelLinkButtonStyle())
            if model.resume != nil || model.hasVisibleQueue {
                // Reopen is on the line only when it leads; otherwise here.
                Button("Reopen") { actions.perform(.restoreClosedPage) }
                    .buttonStyle(KeelLinkButtonStyle(color: KeelDesign.Surface.ink))
            }
        }
        .padding(.horizontal, KeelDesign.Inset.card)
        .frame(height: Self.rowHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recently closed. \(item.accessibilitySummary)")
    }

    private func queueRow(_ item: KeelQueueItem, position: Int) -> some View {
        let isSelected = interactionState.selectedQueueIDs.contains(item.id)
        let isFocused = interactionState.focusedQueueID == item.id
        let isHovering = hoveredID == item.id
        let isNext = position == 1
        let showsHost = item.secondaryText != item.primaryText && !item.secondaryText.isEmpty

        return HStack(spacing: KeelDesign.Space.snug) {
            // The position is the whole meaning of a FIFO queue. It never
            // disappears; selection and removal get their own reserved slots.
            Text("\(position)")
                .font(KeelDesign.Text.numeric)
                .foregroundStyle(isNext ? KeelDesign.Surface.accent : KeelDesign.Surface.inkTertiary)
                .frame(width: 16, alignment: .trailing)

            KeelFaviconView(icon: item.icon, size: 16, monogramSource: showsHost ? item.secondaryText : item.primaryText)

            Text(item.primaryText)
                .font(KeelDesign.Text.rowTitle)
                .foregroundStyle(KeelDesign.Surface.ink)
                .lineLimit(1)
                .truncationMode(.tail)

            if showsHost {
                Text(item.secondaryText)
                    .font(KeelDesign.Text.detail)
                    .foregroundStyle(KeelDesign.Surface.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 200, alignment: .leading)
            }

            Spacer(minLength: KeelDesign.Space.snug)

            Text(item.capturedAt.keelRelativeDescription(from: fixedNow ?? .now))
                .font(KeelDesign.Text.detail)
                .foregroundStyle(KeelDesign.Surface.inkTertiary)
                .monospacedDigit()

            // Reserved slot: a checkmark while selected, a remove button under
            // the pointer, empty otherwise. The row never reflows on hover.
            ZStack {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(KeelDesign.Surface.accent)
                } else {
                    Button {
                        interactionState.replaceSelection([item.id])
                        requestSelectedDeletion()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(KeelDesign.Surface.inkSecondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Remove from queue")
                    .accessibilityLabel("Remove \(item.primaryText) from queue")
                }
            }
            .frame(width: 28, height: 28)
        }
        .padding(.horizontal, KeelDesign.Inset.card)
        .frame(height: Self.rowHeight)
        .background(
            isSelected ? KeelDesign.Surface.rowSelected
                : isHovering ? KeelDesign.Surface.rowHover
                : isNext && model.resume == nil && model.undo == nil ? KeelDesign.Surface.accent.opacity(0.08)
                : Color.clear
        )
        .overlay(alignment: .leading) {
            // Keyboard focus needs its own mark. Selection alone left arrow
            // keys moving an invisible cursor.
            if isFocused {
                Rectangle()
                    .fill(KeelDesign.Surface.accent)
                    .frame(width: 2)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredID = hovering ? item.id : (hoveredID == item.id ? nil : hoveredID)
        }
        .onTapGesture {
            interactionState.selectQueueItem(item.id, extendsSelection: true)
        }
        .contextMenu {
            Button("Remove from Queue", role: .destructive) {
                interactionState.replaceSelection([item.id])
                requestSelectedDeletion()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Position \(position). \(item.accessibilitySummary)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint("Keel opens the queue in order.")
        .accessibilityAction(named: isSelected ? "Deselect" : "Select for removal") {
            interactionState.selectQueueItem(item.id, extendsSelection: true)
        }
    }

    // MARK: Intent

    private func requestSelectedDeletion() {
        _ = interactionState.handle(.deleteSelection, queueIDs: model.visibleQueueIDs)
        isShowingConfirmation = interactionState.pendingDeletion != nil
    }

    private func requestClearQueue() {
        _ = interactionState.handle(.clearQueue, queueIDs: model.visibleQueueIDs)
        isShowingConfirmation = interactionState.pendingDeletion != nil
    }

    private func confirmPendingDeletion() {
        if let action = interactionState.confirmPendingDeletion() {
            actions.perform(action)
        }
        isShowingConfirmation = false
    }
}
