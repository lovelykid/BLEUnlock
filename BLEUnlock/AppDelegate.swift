import Cocoa
import Quartz
import ServiceManagement

func t(_ key: String) -> String {
    return NSLocalizedString(key, comment: "")
}

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation, NSUserNotificationCenterDelegate, BLEDelegate,
                   NSWindowDelegate, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let ble = BLE()
    let mainMenu = NSMenu()
    let lockRSSIMenu = NSMenu()
    let unlockRSSIMenu = NSMenu()
    let timeoutMenu = NSMenu()
    let lockDelayMenu = NSMenu()
    private struct DeviceRow: Equatable {
        let uuid: UUID
        let title: String
        let searchText: [String]
    }

    private var devicePanel: NSPanel?
    private let deviceSearch = NSSearchField()
    private let deviceTable = NSTableView()
    private var deviceRows: [DeviceRow] = []
    private var deviceRowsUpdatePending = false
    private lazy var chooseDeviceButton = NSButton(title: t("choose_device"),
                                                    target: self, action: #selector(selectDevice))
    var monitorMenuItem : NSMenuItem?
    let prefs = UserDefaults.standard
    var displaySleep = false
    var systemSleep = false
    var connected = false
    var userNotification: NSUserNotification?
    var nowPlayingWasPlaying = false
    var aboutBox: AboutBox? = nil
    var wakeTimer: Timer?
    var manualLock = false
    var unlockedAt = 0.0
    var inScreensaver = false
    var lastRSSI: Int? = nil

    func menuWillOpen(_ menu: NSMenu) {
        if menu == lockRSSIMenu {
            for item in menu.items {
                if item.tag == ble.lockRSSI {
                    item.state = .on
                } else {
                    item.state = .off
                }
            }
        } else if menu == unlockRSSIMenu {
            for item in menu.items {
                if item.tag == ble.unlockRSSI {
                    item.state = .on
                } else {
                    item.state = .off
                }
            }
        } else if menu == timeoutMenu {
            for item in menu.items {
                if item.tag == Int(ble.signalTimeout) {
                    item.state = .on
                } else {
                    item.state = .off
                }
            }
        } else if menu == lockDelayMenu {
            for item in menu.items {
                if item.tag == Int(ble.proximityTimeout) {
                    item.state = .on
                } else {
                    item.state = .off
                }
            }
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.menu == lockRSSIMenu {
            return menuItem.tag <= ble.unlockRSSI
        } else if menuItem.menu == unlockRSSIMenu {
            return menuItem.tag >= ble.lockRSSI
        }
        return true
    }
    
    @objc private func showDevices() {
        if devicePanel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 540, height: 340),
                                styleMask: [.titled, .closable, .resizable],
                                backing: .buffered, defer: false)
            panel.title = t("device")
            panel.delegate = self
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.contentMinSize = NSSize(width: 380, height: 220)
            panel.center()

            deviceSearch.placeholderString = t("search_devices")
            deviceSearch.delegate = self

            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("device"))
            column.resizingMask = .autoresizingMask
            deviceTable.addTableColumn(column)
            deviceTable.headerView = nil
            deviceTable.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
            deviceTable.dataSource = self
            deviceTable.delegate = self
            deviceTable.target = self
            deviceTable.doubleAction = #selector(doubleClickDevice)
            deviceTable.rowHeight = 24

            let scroll = NSScrollView()
            scroll.documentView = deviceTable
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder

            let refresh = NSButton(title: t("refresh_devices"), target: self,
                                   action: #selector(refreshDevices))
            let controls = NSStackView(views: [deviceSearch, refresh, chooseDeviceButton])
            deviceSearch.setContentHuggingPriority(.defaultLow, for: .horizontal)
            chooseDeviceButton.isEnabled = false

            let content = panel.contentView!
            controls.translatesAutoresizingMaskIntoConstraints = false
            scroll.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(controls)
            content.addSubview(scroll)
            NSLayoutConstraint.activate([
                controls.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
                controls.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
                controls.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
                scroll.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 10),
                scroll.leadingAnchor.constraint(equalTo: controls.leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: controls.trailingAnchor),
                scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
            ])
            devicePanel = panel
        }

        NSApp.activate(ignoringOtherApps: true)
        devicePanel?.makeKeyAndOrderFront(nil)
        devicePanel?.makeFirstResponder(deviceSearch)
        ble.startScanning()
        updateDeviceRows()
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === devicePanel {
            ble.stopScanning()
        }
    }

    @objc private func refreshDevices() {
        for device in ble.devices.values {
            device.blName = nil
            device.macAddr = nil
        }
        ble.refreshScan()
        updateDeviceRows()
    }

    func controlTextDidChange(_ notification: Notification) {
        updateDeviceRows()
    }

    private var selectedDeviceID: UUID? {
        let row = deviceTable.selectedRow
        return deviceRows.indices.contains(row) ? deviceRows[row].uuid : nil
    }

    private func updateDeviceRows() {
        guard devicePanel?.isVisible == true else { return }

        let query = deviceSearch.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let rows = ble.devices.values.map { device -> DeviceRow in
            let name = device.description
            let uuid = device.uuid.uuidString
            let mac = device.macAddr?.replacingOccurrences(of: "-", with: ":").uppercased()
            let identifier = mac ?? uuid
            let label = name.caseInsensitiveCompare(device.macAddr ?? uuid) == .orderedSame
                ? identifier : "\(name) (\(identifier))"
            let title = "\(device.uuid == ble.monitoredUUID ? "✓ " : "")\(label) (\(device.rssi) dBm)"
            let searchText = [name, uuid, mac, device.macAddr, device.advertisedName,
                              device.blName, device.peripheral?.name, device.manufacture, device.model]
            return DeviceRow(uuid: device.uuid, title: title, searchText: searchText.compactMap { $0 })
        }.filter { row in
            query.isEmpty || row.searchText.contains { $0.localizedCaseInsensitiveContains(query) }
        }.sorted { $0.uuid.uuidString < $1.uuid.uuidString }

        guard rows != deviceRows else { return }
        let selection = selectedDeviceID
        deviceRows = rows
        deviceTable.reloadData()
        if let row = rows.firstIndex(where: { $0.uuid == selection }) {
            deviceTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            deviceTable.deselectAll(nil)
        }
        chooseDeviceButton.isEnabled = selectedDeviceID != nil
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        return deviceRows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let device = deviceRows[row]
        let label = NSTextField(labelWithString: device.title)
        label.lineBreakMode = .byTruncatingMiddle
        label.toolTip = device.title
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        chooseDeviceButton.isEnabled = selectedDeviceID != nil
    }

    private func scheduleDeviceRowsUpdate() {
        guard devicePanel?.isVisible == true, !deviceRowsUpdatePending else { return }
        deviceRowsUpdatePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(200)) { [weak self] in
            guard let self = self else { return }
            self.deviceRowsUpdatePending = false
            self.updateDeviceRows()
        }
    }

    func newDevice(device: Device) {
        scheduleDeviceRowsUpdate()
    }

    func updateDevice(device: Device) {
        scheduleDeviceRowsUpdate()
    }

    func removeDevice(device: Device) {
        scheduleDeviceRowsUpdate()
    }

    func updateRSSI(rssi: Int?, active: Bool) {
        if let r = rssi {
            lastRSSI = r
            monitorMenuItem?.title = String(format:"%ddBm", r) + (active ? " (Active)" : "")
            if (!connected) {
                connected = true
                statusItem.button?.image = NSImage(named: "StatusBarConnected")
            }
        } else {
            monitorMenuItem?.title = t("not_detected")
            if (connected) {
                connected = false
                statusItem.button?.image = NSImage(named: "StatusBarDisconnected")
            }
        }
    }

    func bluetoothPowerWarn() {
        errorModal(t("bluetooth_power_warn"))
    }

    func notifyUser(_ reason: String) {
        let un = NSUserNotification()
        un.title = "BLEUnlock"
        if reason == "lost" {
            un.subtitle = t("notification_lost_signal")
        } else if reason == "away" {
            un.subtitle = t("notification_device_away")
        }
        un.informativeText = t("notification_locked")
        un.deliveryDate = Date().addingTimeInterval(1)
        NSUserNotificationCenter.default.scheduleNotification(un)
        userNotification = un
    }

    func userNotificationCenter(_ center: NSUserNotificationCenter,
                                shouldPresent notification: NSUserNotification) -> Bool {
        return true
    }

    func userNotificationCenter(_ center: NSUserNotificationCenter,
                                didActivate notification: NSUserNotification) {
        if notification != userNotification {
            NSWorkspace.shared.open(URL(string: "https://github.com/ts1/BLEUnlock/releases")!)
            NSUserNotificationCenter.default.removeDeliveredNotification(notification)
        }
    }

    func runScript(_ arg: String) {
        guard let directory = try? FileManager.default.url(for: .applicationScriptsDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return }
        let file = directory.appendingPathComponent("event")
        let process = Process()
        process.executableURL = file
        if let r = lastRSSI {
            process.arguments = [arg, String(r)]
        } else {
            process.arguments = [arg]
        }
        try? process.run()
    }

    func pauseNowPlaying() {
        guard prefs.bool(forKey: "pauseItunes") else { return }
        MRMediaRemoteGetNowPlayingApplicationIsPlaying(
            DispatchQueue.main,
            { (playing) in
                self.nowPlayingWasPlaying = playing
                if self.nowPlayingWasPlaying {
                    print("pause")
                    MRMediaRemoteSendCommand(MRCommandPause, nil)
                }
            }
        )
    }
    
    func playNowPlaying() {
        guard prefs.bool(forKey: "pauseItunes") else { return }
        if nowPlayingWasPlaying {
            print("play")
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false, block: { _ in
                MRMediaRemoteSendCommand(MRCommandPlay, nil)
                self.nowPlayingWasPlaying = false
            })
        }
    }

    func lockOrSaveScreen() {
        if prefs.bool(forKey: "screensaver") {
            NSWorkspace.shared.launchApplication("ScreenSaverEngine")
        } else {
            if SACLockScreenImmediate() != 0 {
                print("Failed to lock screen")
            }
            if prefs.bool(forKey: "sleepDisplay") {
                print("sleep display")
                sleepDisplay()
            }
        }
    }

    func updatePresence(presence: Bool, reason: String) {
        if presence {
            if ble.unlockRSSI != ble.UNLOCK_DISABLED {
                if let un = userNotification {
                    NSUserNotificationCenter.default.removeDeliveredNotification(un)
                    userNotification = nil
                }
                if displaySleep && !systemSleep && prefs.bool(forKey: "wakeOnProximity") {
                    print("Waking display")
                    wakeDisplay()
                    wakeTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true, block: { _ in
                        print("Retrying waking display")
                        wakeDisplay()
                    })
                }
                tryUnlockScreen()
            }
        } else {
            if (!isScreenLocked() && ble.lockRSSI != ble.LOCK_DISABLED) {
                pauseNowPlaying()
                lockOrSaveScreen()
                notifyUser(reason)
                runScript(reason)
            }
            manualLock = false
        }
    }

    func fakeKeyStrokes(_ string: String) {
        let src = CGEventSource(stateID: .hidSystemState)
        // Send 20 characters per keyboard event. That seems to be the limit.
        let PER = 20
        let uniCharCount = string.utf16.count
        var strIndex = string.utf16.startIndex
        for offset in stride(from: 0, to: uniCharCount, by: PER) {
            let pressEvent = CGEvent(keyboardEventSource: src, virtualKey: 49, keyDown: true)
            let len = offset + PER < uniCharCount ? PER : uniCharCount - offset
            let buffer = UnsafeMutablePointer<UniChar>.allocate(capacity: len)
            for i in 0..<len {
                buffer[i] = string.utf16[strIndex]
                strIndex = string.utf16.index(after: strIndex)
            }
            pressEvent?.keyboardSetUnicodeString(stringLength: len, unicodeString: buffer)
            pressEvent?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: src, virtualKey: 49, keyDown: false)?.post(tap: .cghidEventTap)
        }
        
        // Return key
        CGEvent(keyboardEventSource: src, virtualKey: 52, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: src, virtualKey: 52, keyDown: false)?.post(tap: .cghidEventTap)
    }

    func isScreenLocked() -> Bool {
        if let dict = CGSessionCopyCurrentDictionary() as? [String : Any] {
            if let locked = dict["CGSSessionScreenIsLocked"] as? Int {
                return locked == 1
            }
        }
        return false
    }
    
    func tryUnlockScreen() {
        guard !manualLock else { return }
        guard ble.presence else { return }
        guard ble.unlockRSSI != ble.UNLOCK_DISABLED else { return }
        guard !systemSleep else { return }
        guard !displaySleep else { return }

        if inScreensaver {
            // In screensaver, make sure Login panel is displayed
            let src = CGEventSource(stateID: .hidSystemState)
            // Esc key down and up
            CGEvent(keyboardEventSource: src, virtualKey: 0x35, keyDown: true)?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: src, virtualKey: 0x35, keyDown: false)?.post(tap: .cghidEventTap)
        }

        guard !self.prefs.bool(forKey: "wakeWithoutUnlocking") else { return }

        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false, block: { _ in
            guard self.isScreenLocked() else { return }
            guard let password = self.fetchPassword(warn: true) else { return }
            
            print("Entering password")
            self.unlockedAt = Date().timeIntervalSince1970
            self.fakeKeyStrokes(password)
            self.playNowPlaying()
            self.runScript("unlocked")
        })
    }

    @objc func onDisplayWake() {
        print("display wake")
        //unlockedAt = Date().timeIntervalSince1970
        displaySleep = false
        wakeTimer?.invalidate()
        wakeTimer = nil
        tryUnlockScreen()
    }

    @objc func onDisplaySleep() {
        print("display sleep")
        displaySleep = true
    }

    @objc func onSystemWake() {
        print("system wake")
        Timer.scheduledTimer(withTimeInterval: 1, repeats: false, block: { _ in
            print("delayed system wake job")
            NSApp.setActivationPolicy(.accessory) // Hide Dock icon again
            self.systemSleep = false
            self.tryUnlockScreen()
        })
    }
    
    @objc func onSystemSleep() {
        print("system sleep")
        systemSleep = true
        // Set activation policy to regular, so the CBCentralManager can scan for peripherals
        // when the Bluetooth will become on again.
        // This enables Dock icon but the screen is off anyway.
        NSApp.setActivationPolicy(.regular)
    }

    @objc func onUnlock() {
        Timer.scheduledTimer(withTimeInterval: 2, repeats: false, block: { _ in
            print("onUnlock")
            if Date().timeIntervalSince1970 >= self.unlockedAt + 10 {
                if self.ble.unlockRSSI != self.ble.UNLOCK_DISABLED {
                    self.runScript("intruded")
                }
                self.playNowPlaying()
            }
        })
        manualLock = false
        Timer.scheduledTimer(withTimeInterval: 2, repeats: false, block: { _ in
            checkUpdate()
        })
    }

    @objc func onScreensaverStart() {
        print("screensaver start")
        inScreensaver = true
    }

    @objc func onScreensaverStop() {
        print("screensaver stop")
        inScreensaver = false
    }

    @objc private func doubleClickDevice() {
        guard deviceTable.clickedRow >= 0 else { return }
        selectDevice()
    }

    @objc private func selectDevice() {
        guard let uuid = selectedDeviceID, ble.devices[uuid] != nil else { return }
        devicePanel?.close()
        monitorDevice(uuid: uuid)
        prefs.set(uuid.uuidString, forKey: "device")
    }

    func monitorDevice(uuid: UUID) {
        connected = false
        statusItem.button?.image = NSImage(named: "StatusBarDisconnected")
        monitorMenuItem?.title = t("not_detected")
        ble.startMonitor(uuid: uuid)
    }

    func errorModal(_ msg: String, info: String? = nil) {
        let alert = NSAlert()
        alert.messageText = msg
        alert.informativeText = info ?? ""
        alert.window.title = "BLEUnlock"
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
    
    func storePassword(_ password: String) {
        let pw = password.data(using: .utf8)!
        
        let query: [String: Any] = [
            String(kSecClass): kSecClassGenericPassword,
            String(kSecAttrAccount): NSUserName(),
            String(kSecAttrService): Bundle.main.bundleIdentifier ?? "BLEUnlock",
            String(kSecAttrLabel): "BLEUnlock",
            String(kSecValueData): pw,
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            let err = SecCopyErrorMessageString(status, nil)
            errorModal("Failed to store password to Keychain", info: err as String? ?? "Status \(status)")
            return
        }
    }

    func fetchPassword(warn: Bool = false) -> String? {
        let query: [String: Any] = [
            String(kSecClass): kSecClassGenericPassword,
            String(kSecAttrAccount): NSUserName(),
            String(kSecAttrService): Bundle.main.bundleIdentifier ?? "BLEUnlock",
            String(kSecReturnData): kCFBooleanTrue!,
            String(kSecMatchLimit): kSecMatchLimitOne,
        ]
        
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if (status == errSecItemNotFound) {
            print("Password is not stored")
            if warn {
                errorModal(t("password_not_set"))
            }
            return nil
        }
        guard status == errSecSuccess else {
            let info = SecCopyErrorMessageString(status, nil)
            errorModal("Failed to retrieve password", info: info as String? ?? "Status \(status)")
            return nil
        }
        guard let data = item as? Data else {
            errorModal("Failed to convert password")
            return nil
        }
        return String(data: data, encoding: .utf8)!
    }
    
    @objc func askPassword() {
        let msg = NSAlert()
        msg.addButton(withTitle: t("ok"))
        msg.addButton(withTitle: t("cancel"))
        msg.messageText = t("enter_password")
        msg.informativeText = t("password_info")
        msg.window.title = "BLEUnlock"

        let txt = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 20))
        msg.accessoryView = txt
        txt.becomeFirstResponder()
        NSApp.activate(ignoringOtherApps: true)
        let response = msg.runModal()
        
        if (response == .alertFirstButtonReturn) {
            let pw = txt.stringValue
            storePassword(pw)
        }
    }
    
    @objc func setRSSIThreshold() {
        let msg = NSAlert()
        msg.addButton(withTitle: t("ok"))
        msg.addButton(withTitle: t("cancel"))
        msg.messageText = t("enter_rssi_threshold")
        msg.informativeText = t("enter_rssi_threshold_info")
        msg.window.title = "BLEUnlock"
        
        let txt = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 20))
        txt.placeholderString = String(ble.thresholdRSSI)
        msg.accessoryView = txt
        txt.becomeFirstResponder()
        NSApp.activate(ignoringOtherApps: true)
        let response = msg.runModal()
        
        if (response == .alertFirstButtonReturn) {
            let val = txt.intValue
            ble.thresholdRSSI = Int(val)
            prefs.set(val, forKey: "thresholdRSSI")
        }
    }

    @objc func toggleWakeOnProximity(_ menuItem: NSMenuItem) {
        let value = !prefs.bool(forKey: "wakeOnProximity")
        menuItem.state = value ? .on : .off
        prefs.set(value, forKey: "wakeOnProximity")
    }

    @objc func setLockRSSI(_ menuItem: NSMenuItem) {
        let value = menuItem.tag
        prefs.set(value, forKey: "lockRSSI")
        ble.lockRSSI = value
    }
    
    @objc func setUnlockRSSI(_ menuItem: NSMenuItem) {
        let value = menuItem.tag
        prefs.set(value, forKey: "unlockRSSI")
        ble.unlockRSSI = value
    }

    @objc func setTimeout(_ menuItem: NSMenuItem) {
        let value = menuItem.tag
        prefs.set(value, forKey: "timeout")
        ble.signalTimeout = Double(value)
    }

    @objc func setLockDelay(_ menuItem: NSMenuItem) {
        let value = menuItem.tag
        prefs.set(value, forKey: "lockDelay")
        ble.proximityTimeout = Double(value)
    }

    @objc func toggleLaunchAtLogin(_ menuItem: NSMenuItem) {
        let launchAtLogin = !prefs.bool(forKey: "launchAtLogin")
        prefs.set(launchAtLogin, forKey: "launchAtLogin")
        menuItem.state = launchAtLogin ? .on : .off
        SMLoginItemSetEnabled(Bundle.main.bundleIdentifier! + ".Launcher" as CFString, launchAtLogin)
    }

    @objc func togglePauseNowPlaying(_ menuItem: NSMenuItem) {
        let pauseNowPlaying = !prefs.bool(forKey: "pauseItunes")
        prefs.set(pauseNowPlaying, forKey: "pauseItunes")
        menuItem.state = pauseNowPlaying ? .on : .off
    }
    
    @objc func toggleUseScreensaver(_ menuItem: NSMenuItem) {
        let value = !prefs.bool(forKey: "screensaver")
        prefs.set(value, forKey: "screensaver")
        menuItem.state = value ? .on : .off
    }

    @objc func toggleSleepDisplay(_ menuItem: NSMenuItem) {
        let value = !prefs.bool(forKey: "sleepDisplay")
        prefs.set(value, forKey: "sleepDisplay")
        menuItem.state = value ? .on : .off
    }
    
    @objc func togglePassiveMode(_ menuItem: NSMenuItem) {
        let passiveMode = !prefs.bool(forKey: "passiveMode")
        prefs.set(passiveMode, forKey: "passiveMode")
        menuItem.state = passiveMode ? .on : .off
        ble.setPassiveMode(passiveMode)
    }

    @objc func toggleWakeWithoutUnlocking(_ menuItem: NSMenuItem) {
        let wakeWithoutUnlocking = !prefs.bool(forKey: "wakeWithoutUnlocking")
        prefs.set(wakeWithoutUnlocking, forKey: "wakeWithoutUnlocking")
        menuItem.state = wakeWithoutUnlocking ? .on : .off
    }

    @objc func lockNow() {
        guard !isScreenLocked() else { return }
        manualLock = true
        pauseNowPlaying()
        lockOrSaveScreen()
    }
    
    @objc func showAboutBox() {
        AboutBox.showAboutBox()
    }

    func constructRSSIMenu(_ menu: NSMenu, _ action: Selector) {
        menu.addItem(withTitle: t("closer"), action: nil, keyEquivalent: "")
        for proximity in stride(from: -30, to: -100, by: -5) {
            let item = menu.addItem(withTitle: String(format: "%ddBm", proximity), action: action, keyEquivalent: "")
            item.tag = proximity
        }
        menu.addItem(withTitle: t("farther"), action: nil, keyEquivalent: "")
        menu.delegate = self
    }
    
    func constructMenu() {
        monitorMenuItem = mainMenu.addItem(withTitle: t("device_not_set"), action: nil, keyEquivalent: "")
        
        var item: NSMenuItem

        item = mainMenu.addItem(withTitle: t("lock_now"), action: #selector(lockNow), keyEquivalent: "")
        mainMenu.addItem(NSMenuItem.separator())

        mainMenu.addItem(withTitle: t("device"), action: #selector(showDevices), keyEquivalent: "")

        let unlockRSSIItem = mainMenu.addItem(withTitle: t("unlock_rssi"), action: nil, keyEquivalent: "")
        unlockRSSIItem.submenu = unlockRSSIMenu
        item = unlockRSSIMenu.addItem(withTitle: t("disabled"), action: #selector(setUnlockRSSI), keyEquivalent: "")
        item.tag = ble.UNLOCK_DISABLED
        constructRSSIMenu(unlockRSSIMenu, #selector(setUnlockRSSI))

        let lockRSSIItem = mainMenu.addItem(withTitle: t("lock_rssi"), action: nil, keyEquivalent: "")
        lockRSSIItem.submenu = lockRSSIMenu
        constructRSSIMenu(lockRSSIMenu, #selector(setLockRSSI))
        item = lockRSSIMenu.addItem(withTitle: t("disabled"), action: #selector(setLockRSSI), keyEquivalent: "")
        item.tag = ble.LOCK_DISABLED

        let lockDelayItem = mainMenu.addItem(withTitle: t("lock_delay"), action: nil, keyEquivalent: "")
        lockDelayItem.submenu = lockDelayMenu
        lockDelayMenu.addItem(withTitle: "2 " + t("seconds"), action: #selector(setLockDelay), keyEquivalent: "").tag = 2
        lockDelayMenu.addItem(withTitle: "5 " + t("seconds"), action: #selector(setLockDelay), keyEquivalent: "").tag = 5
        lockDelayMenu.addItem(withTitle: "15 " + t("seconds"), action: #selector(setLockDelay), keyEquivalent: "").tag = 15
        lockDelayMenu.addItem(withTitle: "30 " + t("seconds"), action: #selector(setLockDelay), keyEquivalent: "").tag = 30
        lockDelayMenu.addItem(withTitle: "1 " + t("minute"), action: #selector(setLockDelay), keyEquivalent: "").tag = 60
        lockDelayMenu.addItem(withTitle: "2 " + t("minutes"), action: #selector(setLockDelay), keyEquivalent: "").tag = 120
        lockDelayMenu.addItem(withTitle: "5 " + t("minutes"), action: #selector(setLockDelay), keyEquivalent: "").tag = 300
        lockDelayMenu.delegate = self

        let timeoutItem = mainMenu.addItem(withTitle: t("timeout"), action: nil, keyEquivalent: "")
        timeoutItem.submenu = timeoutMenu
        timeoutMenu.addItem(withTitle: "30 " + t("seconds"), action: #selector(setTimeout), keyEquivalent: "").tag = 30
        timeoutMenu.addItem(withTitle: "1 " + t("minute"), action: #selector(setTimeout), keyEquivalent: "").tag = 60
        timeoutMenu.addItem(withTitle: "2 " + t("minutes"), action: #selector(setTimeout), keyEquivalent: "").tag = 120
        timeoutMenu.addItem(withTitle: "5 " + t("minutes"), action: #selector(setTimeout), keyEquivalent: "").tag = 300
        timeoutMenu.addItem(withTitle: "10 " + t("minutes"), action: #selector(setTimeout), keyEquivalent: "").tag = 600
        timeoutMenu.delegate = self

        item = mainMenu.addItem(withTitle: t("wake_on_proximity"), action: #selector(toggleWakeOnProximity), keyEquivalent: "")
        if prefs.bool(forKey: "wakeOnProximity") {
            item.state = .on
        }

        item = mainMenu.addItem(withTitle: t("wake_without_unlocking"), action: #selector(toggleWakeWithoutUnlocking), keyEquivalent: "")
        if prefs.bool(forKey: "wakeWithoutUnlocking") {
            item.state = .on
        }

        item = mainMenu.addItem(withTitle: t("pause_now_playing"), action: #selector(togglePauseNowPlaying), keyEquivalent: "")
        if prefs.bool(forKey: "pauseItunes") {
            item.state = .on
        }

        item = mainMenu.addItem(withTitle: t("use_screensaver_to_lock"), action: #selector(toggleUseScreensaver), keyEquivalent: "")
        if prefs.bool(forKey: "screensaver") {
            item.state = .on
        }

        item = mainMenu.addItem(withTitle: t("sleep_display"), action: #selector(toggleSleepDisplay), keyEquivalent: "")
        if prefs.bool(forKey: "sleepDisplay") {
            item.state = .on
        }
        
        mainMenu.addItem(withTitle: t("set_password"), action: #selector(askPassword), keyEquivalent: "")

        item = mainMenu.addItem(withTitle: t("passive_mode"), action: #selector(togglePassiveMode), keyEquivalent: "")
        item.state = prefs.bool(forKey: "passiveMode") ? .on : .off
        
        item = mainMenu.addItem(withTitle: t("launch_at_login"), action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        item.state = prefs.bool(forKey: "launchAtLogin") ? .on : .off
        
        mainMenu.addItem(withTitle: t("set_rssi_threshold"), action: #selector(setRSSIThreshold),
                         keyEquivalent: "")

        mainMenu.addItem(NSMenuItem.separator())
        mainMenu.addItem(withTitle: t("about"), action: #selector(showAboutBox), keyEquivalent: "")
        mainMenu.addItem(NSMenuItem.separator())
        mainMenu.addItem(withTitle: t("quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        statusItem.menu = mainMenu
    }

    func checkAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeRetainedValue() as String
        if (!AXIsProcessTrustedWithOptions([key: true] as CFDictionary)) {
            // Sometimes Prompt option above doesn't work.
            // Actually trying to send key may open that dialog.
            let src = CGEventSource(stateID: .hidSystemState)
            // "Fn" key down and up
            CGEvent(keyboardEventSource: src, virtualKey: 63, keyDown: true)?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: src, virtualKey: 63, keyDown: false)?.post(tap: .cghidEventTap)
        }
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        if let button = statusItem.button {
            button.image = NSImage(named: "StatusBarDisconnected")
            constructMenu()
        }
        ble.delegate = self
        if let str = prefs.string(forKey: "device") {
            if let uuid = UUID(uuidString: str) {
                monitorDevice(uuid: uuid)
            }
        }
        let lockRSSI = prefs.integer(forKey: "lockRSSI")
        if lockRSSI != 0 {
            ble.lockRSSI = lockRSSI
        }
        let unlockRSSI = prefs.integer(forKey: "unlockRSSI")
        if unlockRSSI != 0 {
            ble.unlockRSSI = unlockRSSI
        }
        let timeout = prefs.integer(forKey: "timeout")
        if timeout != 0 {
            ble.signalTimeout = Double(timeout)
        }
        ble.setPassiveMode(prefs.bool(forKey: "passiveMode"))
        let thresholdRSSI = prefs.integer(forKey: "thresholdRSSI")
        if thresholdRSSI != 0 {
            ble.thresholdRSSI = thresholdRSSI
        }
        let lockDelay = prefs.integer(forKey: "lockDelay")
        if lockDelay != 0 {
            ble.proximityTimeout = Double(lockDelay)
        }

        NSUserNotificationCenter.default.delegate = self

        let nc = NSWorkspace.shared.notificationCenter;
        nc.addObserver(self, selector: #selector(onDisplaySleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(onDisplayWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        nc.addObserver(self, selector: #selector(onSystemSleep), name: NSWorkspace.willSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(onSystemWake), name: NSWorkspace.didWakeNotification, object: nil)

        let dnc = DistributedNotificationCenter.default
        dnc.addObserver(self, selector: #selector(onUnlock), name: NSNotification.Name(rawValue: "com.apple.screenIsUnlocked"), object: nil)
        dnc.addObserver(self, selector: #selector(onScreensaverStart), name: NSNotification.Name(rawValue: "com.apple.screensaver.didstart"), object: nil)
        dnc.addObserver(self, selector: #selector(onScreensaverStop), name: NSNotification.Name(rawValue: "com.apple.screensaver.didstop"), object: nil)

        if ble.unlockRSSI != ble.UNLOCK_DISABLED && !prefs.bool(forKey: "wakeWithoutUnlocking") && fetchPassword() == nil {
            askPassword()
        }
        checkAccessibility()
        checkUpdate()

        // Hide dock icon.
        // This is required because we can't have LSUIElement set to true in Info.plist,
        // otherwise CBCentralManager.scanForPeripherals won't work.
        NSApp.setActivationPolicy(.accessory)
    }
    
    func applicationWillTerminate(_ aNotification: Notification) {
    }
}
