//
// Vespertine Remote: the phone bench, started by a launch argument (debug builds only; see LaunchOptions). It plays the
// test songs put in the app's Library/VTBench/music folder through the phone's player, measures what comes out and
// quits, so that a Mac the phone is plugged into can run it and read the report with nobody touching the phone:
//   xcrun devicectl device process launch --console --terminate-existing --device <phone> <bundle id> -VTBench YES
// The sound does come out of the phone while it runs.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

#if DEBUG
import Foundation
import UIKit
import VespertinePhoneBench

enum BenchLaunch {
    static func runIfAsked() async {
        guard let asked = LaunchOptions.bench, !asked.isEmpty, asked.uppercased() != "NO" else { return }
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let base = home.appendingPathComponent("Library/VTBench", isDirectory: true)
        let folder = asked.uppercased() == "YES" ? base.appendingPathComponent("music", isDirectory: true) : home.appendingPathComponent(asked, isDirectory: true)
        UIApplication.shared.isIdleTimerDisabled = true
        let bench = PhoneBench(folder: folder, results: base.appendingPathComponent("results", isDirectory: true))
        bench.progress = { line in
            print("VTBENCH … \(line)")
            fflush(stdout)
        }
        let report = await bench.run()
        print(report.text)
        fflush(stdout)
        // Nothing to measure is a failure of the run; what was measured is for whoever reads the report to judge.
        exit(report.joins.isEmpty && report.gains.isEmpty ? 1 : 0)
    }
}
#endif
