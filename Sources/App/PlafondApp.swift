import SwiftUI

@main
struct PlafondApp: App {
    @StateObject private var model: AppModel

    init() {
        let m = AppModel()
        _model = StateObject(wrappedValue: m)
        Snapshot.runIfRequested(model: m)
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView().environmentObject(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let b = model.battery
        let badge: MenuBarIcon.Badge =
            model.helper.status?.adapterDisabled == true && b.adapterPresent ? .discharging :
            b.isCharging ? .charging :
            b.adapterPresent ? .plugged : .none
        Image(nsImage: MenuBarIcon.image(percent: b.percent,
                                         limit: model.limitEnabled ? model.effectiveLimit : nil,
                                         badge: badge,
                                         showPercent: model.showPercent))
    }
}
