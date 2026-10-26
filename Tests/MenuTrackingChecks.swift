import AppKit
import SwiftUI

@main
struct MenuTrackingChecks {
    @MainActor static func main() {
        let model = SpectrumModel()
        model.demo = true
        model.start()
        var changes = 0
        var previous = model.bands
        let deadline = Date().addingTimeInterval(0.45)
        while Date() < deadline {
            RunLoop.main.run(mode: .eventTracking, before: min(deadline, Date().addingTimeInterval(0.04)))
            if model.bands != previous { changes += 1; previous = model.bands }
        }
        precondition(changes >= 3, "Spectrum stopped updating during menu tracking")
        precondition(model.bands.contains { $0 > 0 }, "Demo FFT must receive audio during menu tracking")
        precondition(model.vuLevels.contains { $0 > 0 }, "VU levels must update during menu tracking")
        model.setPresentationActive(false)
        precondition(model.enabled && !model.running, "Hidden visualization must suspend without disabling the user's setting")
        precondition(model.bands.allSatisfy { $0 == 0 } && model.vuLevels.allSatisfy { $0 == 0 })
        let pausedUntil = Date().addingTimeInterval(0.12)
        while Date() < pausedUntil { RunLoop.main.run(mode: .eventTracking, before: pausedUntil) }
        precondition(!model.running && model.bands.allSatisfy { $0 == 0 }, "Hidden processing must stay stopped")
        model.setPresentationActive(true)
        precondition(model.enabled && model.running, "Visible visualizer must resume")
        let resumeUntil = Date().addingTimeInterval(0.12)
        while Date() < resumeUntil { RunLoop.main.run(mode: .eventTracking, before: resumeUntil) }
        precondition(model.bands.contains { $0 > 0 }, "Resuming must produce new FFT frames")
        model.stop()
        model.setPresentationActive(false)
        model.setPresentationActive(true)
        precondition(!model.enabled && !model.running, "Visibility changes must not undo explicit Stop")
        model.setPresentationActive(false)
        model.start()
        precondition(model.enabled && !model.running, "Start while hidden must defer capture")
        model.setPresentationActive(true)
        precondition(model.running, "Deferred start must resume when visible")
        model.stop()
        precondition(model.bands.allSatisfy { $0 == 0 } && model.vuLevels.allSatisfy { $0 == 0 })
        print("PASS: menu tracking, hidden suspension, automatic resume, deferred start, and explicit Stop.")
    }
}
