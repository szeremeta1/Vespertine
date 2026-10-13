//
// Vespertine — the loopback self-test sheet: setup, running, results per format and per channel.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import VespertineAudio

struct LoopbackTestSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var expanded = Set<String>()
    @State private var copied = false

    private var test: LoopbackTest { model.loopback }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Loopback Test").font(Typeface.serif(24)).foregroundStyle(Palette.text)
                Text("A software-path check. Vespertine plays a test signal through a virtual loopback device with every processing step off, records it back and compares every sample. It shows that decoding, the engine and the Core Audio output deliver the samples exactly. It says nothing about your DAC, a cable or any other hardware, and it never changes the BIT-PERFECT badge.")
                    .font(Typeface.ui(12.5)).foregroundStyle(Palette.text2).fixedSize(horizontal: false, vertical: true)
            }
            .padding([.horizontal, .top], 22)
            .padding(.bottom, 14)
            Hairline()
            Group {
                switch test.phase {
                case .setup: setup
                case .running: running
                case .finished: results
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Hairline()
            footer
        }
        .frame(width: 720, height: 600)
        .background(Palette.panel)
        .interactiveDismissDisabled(test.phase == .running)
        .onDisappear { test.reset() }
    }

    // MARK: Setup

    private var setup: some View {
        @Bindable var test = model.loopback
        let candidates = LoopbackTest.candidates(model.devices.devices)
        let output = test.output(in: model.devices.devices)
        return VStack(alignment: .leading, spacing: 14) {
            if candidates.isEmpty {
                Text("No loopback device")
                    .font(Typeface.serif(17)).foregroundStyle(Palette.text)
                Text("The test needs a virtual loopback device, so the full-scale test signal never reaches speakers or headphones. Install the dedicated \u{201C}\(LoopbackGuard.deviceName)\u{201D} device with scripts/install-loopback-device.sh from Vespertine's source. It is a separate copy of BlackHole, so a BlackHole you already use isn't touched.")
                    .font(Typeface.ui(12)).foregroundStyle(Palette.text2).fixedSize(horizontal: false, vertical: true)
            } else {
                Picker("Loopback device", selection: Binding(get: { output?.uid ?? "" }, set: { test.outputUID = $0 })) {
                    ForEach(candidates, id: \.uid) { Text($0.name).tag($0.uid) }
                }
                .frame(maxWidth: 420)
                if let output, output.name != LoopbackGuard.deviceName {
                    Text("Use \u{201C}\(output.name)\u{201D} only while nothing else is playing to or recording from it. A dedicated \u{201C}\(LoopbackGuard.deviceName)\u{201D} device avoids that.")
                        .font(Typeface.ui(11)).foregroundStyle(Palette.copper).fixedSize(horizontal: false, vertical: true)
                }
                Picker("Test", selection: $test.mode) {
                    Text("Quick (about 10 seconds)").tag(LoopbackMode.quick)
                    Text("Full (one to two minutes)").tag(LoopbackMode.full)
                }
                .pickerStyle(.radioGroup)
                Text(test.mode == .quick
                     ? "24-bit at two sample rates, a 16-bit file and a gapless pair."
                     : "Every common sample rate from 44.1 to 384 kHz the device offers, at 24-bit, 16-bit padded and matched, and 32-bit in integer mode, plus a gapless pair and a 16-bit to 24-bit switch.")
                    .font(Typeface.ui(11)).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true)
                Text("Playback pauses while the test runs. Your settings are not changed: the test uses its own engine and puts the device's sample rate back afterwards. macOS asks once for permission to record, because the test records the loopback device's input.")
                    .font(Typeface.ui(11)).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(22)
    }

    // MARK: Running

    private var running: some View {
        VStack(spacing: 12) {
            ProgressView(value: test.progress).progressViewStyle(.linear).tint(Palette.brass).frame(width: 320)
            Text("Case \(min(test.done.count + 1, test.total)) of \(test.total)").font(Typeface.mono(11)).foregroundStyle(Palette.text3)
            if let name = test.currentCase { Text(name).font(Typeface.ui(12.5)).foregroundStyle(Palette.text2) }
            if !test.done.isEmpty {
                ScrollView { caseList(test.done).padding(.horizontal, 22) }.frame(maxHeight: 300)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Results

    private var results: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let error = test.error {
                    Text(error).font(Typeface.ui(12.5)).foregroundStyle(Palette.copper).fixedSize(horizontal: false, vertical: true)
                }
                if let report = test.report {
                    HStack(spacing: 10) {
                        StatusBadge(text: report.status.label.uppercased(), kind: report.status == .bitExact ? .perfect : report.status == .failed ? .converted : .neutral)
                        Text(LoopbackReport.label).font(Typeface.ui(12)).foregroundStyle(Palette.text2)
                    }
                    Text(verdict(report)).font(Typeface.ui(12)).foregroundStyle(Palette.text2).fixedSize(horizontal: false, vertical: true)
                    Text("\(report.outputDevice) · Vespertine \(report.appVersion) · macOS \(report.macOS)")
                        .font(Typeface.mono(11)).foregroundStyle(Palette.text3)
                    caseList(report.cases)
                }
            }
            .padding(22)
        }
    }

    private func verdict(_ report: LoopbackReport) -> String {
        switch report.status {
        case .bitExact: String(localized: "Every case that ran came back sample for sample. Vespertine's software path delivered these formats unchanged to the loopback device.")
        case .failed: String(localized: "At least one case came back changed. Open it to see each channel. Copy the report to include it in a bug report.")
        case .setupProblem: String(localized: "The test itself couldn't be trusted, so this says nothing about Vespertine. Check that nothing else uses the loopback device, then run it again.")
        case .skipped: String(localized: "Every case was skipped.")
        }
    }

    private func caseList(_ cases: [LoopbackCaseResult]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(cases) { c in
                VStack(alignment: .leading, spacing: 4) {
                    Button {
                        if expanded.contains(c.id) { expanded.remove(c.id) } else { expanded.insert(c.id) }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: icon(c.status)).foregroundStyle(tint(c.status)).frame(width: 14)
                            Text(c.testCase.name).font(Typeface.ui(12.5)).foregroundStyle(Palette.text)
                            Spacer(minLength: 8)
                            Text(c.summary).font(Typeface.ui(11.5)).foregroundStyle(Palette.text2).lineLimit(1).truncationMode(.tail)
                            Image(systemName: expanded.contains(c.id) ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.text3)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(c.testCase.name): \(c.status.label), \(c.summary)")
                    if expanded.contains(c.id) { details(c).padding(.leading, 24) }
                }
                .padding(.vertical, 7)
                Hairline()
            }
        }
    }

    private func details(_ c: LoopbackCaseResult) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let format = c.deviceFormat { line("Device format: \(format)") }
            if let note = c.sixteenBitNote { line(note) }
            ForEach(Array(c.analyses.enumerated()), id: \.offset) { _, a in
                ForEach(a.channels, id: \.channel) { ch in line(LoopbackReport.describe(ch)) }
                ForEach(Array(a.findings.enumerated()), id: \.offset) { _, f in
                    line(f.isSetupProblem ? String(localized: "Test setup problem: \(f.summary)") : f.summary, tint: Palette.copper)
                }
            }
            if c.engineUnderruns > 0 || c.recorderDiscontinuities > 0 {
                line("Engine underruns: \(c.engineUnderruns) · recorder discontinuities: \(c.recorderDiscontinuities)")
            }
        }
    }

    private func line(_ text: String, tint: Color = Palette.text3) -> some View {
        Text(text).font(Typeface.ui(11)).foregroundStyle(tint).fixedSize(horizontal: false, vertical: true)
    }

    private func icon(_ status: LoopbackCaseResult.Status) -> String {
        switch status {
        case .bitExact: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .setupProblem: "exclamationmark.triangle.fill"
        case .skipped: "minus.circle"
        }
    }

    private func tint(_ status: LoopbackCaseResult.Status) -> Color {
        switch status {
        case .bitExact: Palette.brass
        case .failed, .setupProblem: Palette.copper
        case .skipped: Palette.text3
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if test.phase == .finished, test.report != nil {
                Button(copied ? "Copied" : "Copy Report") {
                    test.copyReport()
                    copied = true
                }
                .buttonStyle(QuietButtonStyle())
                .help("Copies the report as Markdown, for a bug report or a forum post")
            }
            Spacer()
            switch test.phase {
            case .setup:
                Button("Cancel") { dismiss() }.buttonStyle(QuietButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Run Test") {
                    guard let output = test.output(in: model.devices.devices) else { return }
                    copied = false
                    expanded = []
                    Task { await test.run(on: output, player: model.player) }
                }
                .buttonStyle(BrassButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(test.output(in: model.devices.devices) == nil)
            case .running:
                Text("Running…").font(Typeface.ui(12)).foregroundStyle(Palette.text3)
            case .finished:
                Button("Run Again") { copied = false; test.reset() }.buttonStyle(QuietButtonStyle())
                Button("Done") { dismiss() }.buttonStyle(BrassButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }
}
