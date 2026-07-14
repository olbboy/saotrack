import AppKit
import SwiftUI

/// External-tool status and guided install: ffmpeg, yt-dlp, and Demucs,
/// plus the app-managed Python environment option and the GPU toggle.
struct SetupView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    private var locator: ToolLocator { appState.toolLocator }

    var body: some View {
        @Bindable var appState = appState

        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("External Tools")
                    .font(.title2.bold())
                Spacer()
                Button {
                    Task { await locator.refresh() }
                } label: {
                    if locator.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Re-check", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(locator.isRefreshing)
            }

            Text("SaoTrack uses these command-line tools. Install anything marked missing, then press Re-check.")
                .font(.callout)
                .foregroundStyle(.secondary)

            ForEach(locator.statuses) { status in
                toolRow(status)
            }

            Divider()

            managedVenvSection

            Divider()

            Toggle(isOn: $appState.useGPUForSeparation) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use GPU (MPS) for separation — experimental")
                    Text("Faster on Apple Silicon, but some demucs/PyTorch versions fail on MPS. Turn off if separation errors out.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 620, height: 640)
        .task { await locator.refresh() }
    }

    // MARK: - Tool row

    private func toolRow(_ status: ToolStatus) -> some View {
        HStack(alignment: .top, spacing: 12) {
            statusIcon(status.availability)
                .font(.title3)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(status.displayName)
                    .font(.headline)
                Text(status.purpose)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                switch status.availability {
                case .found(let path, let version):
                    Text(version.isEmpty ? path : "\(version) — \(path)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                case .missing:
                    HStack(spacing: 6) {
                        Text(status.installCommand)
                            .font(.caption.monospaced())
                            .padding(.vertical, 2)
                            .padding(.horizontal, 6)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(status.installCommand, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("Copy install command")
                    }
                case .unknown:
                    ProgressView().controlSize(.small)
                }
            }
            Spacer()
        }
        .padding(10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func statusIcon(_ availability: ToolAvailability) -> some View {
        switch availability {
        case .found:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .missing:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .unknown:
            Image(systemName: "circle.dotted").foregroundStyle(.secondary)
        }
    }

    // MARK: - Managed venv

    private var managedVenvSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Managed Python Environment")
                .font(.headline)
            Text("If you don't want to install Demucs yourself, SaoTrack can create its own Python environment in Application Support and install Demucs into it (downloads PyTorch, roughly 2 GB).")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button {
                    Task { await locator.createManagedVenv() }
                } label: {
                    if locator.isCreatingVenv {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Installing…")
                        }
                    } else {
                        Text("Create Managed Environment")
                    }
                }
                .disabled(locator.isCreatingVenv)

                if let error = locator.venvError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }

            if locator.isCreatingVenv || !locator.venvLog.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(locator.venvLog.enumerated()), id: \.offset) { index, line in
                                Text(line)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .id(index)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                    }
                    .frame(height: 110)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                    .onChange(of: locator.venvLog.count) { _, newCount in
                        proxy.scrollTo(max(0, newCount - 1), anchor: .bottom)
                    }
                }
            }
        }
    }
}
