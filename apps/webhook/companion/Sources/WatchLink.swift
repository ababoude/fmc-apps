//! CoreBluetooth side: the link to the watch, the shell (`AT GETSECRET`), and the encrypted channel.
//! Nothing here is unit-tested: it needs a phone and a watch. The framing, crypto and `h1` live in `Wire.swift`,
//! which is shared with the tests.

import Combine
import CoreBluetooth
import Foundation

/// What the watch and this app exchange, decoded.
enum WatchEvent {
    case linked
    case asked
    case run(row: Int)
    case lost
}

/// Owns one `CBCentralManager`, finds the watch, reads the pairing secret and keeps the channel open.
///
/// The watch takes one central, and on the phone that is the system's link Nothing X holds: the app asks iOS for the
/// peripheral that is already connected (`retrieveConnectedPeripherals`) and only scans when there is none.
@MainActor
final class WatchLink: NSObject, ObservableObject {
    enum State: Equatable {
        case off
        case scanning
        case connecting
        case readingSecret
        case ready
        case failed(String)
    }

    private static let commandService = CBUUID(string: "0000FFF0-0000-1000-8000-00805F9B34FB")
    private static let commandWrite = CBUUID(string: "0000FFF2-0000-1000-8000-00805F9B34FB")
    private static let commandNotify = CBUUID(string: "0000FFF1-0000-1000-8000-00805F9B34FB")
    private static let shellService = CBUUID(string: "77D4FF00-2FE2-2334-0D35-9CCD078F529C")
    private static let shellWrite = CBUUID(string: "77D4FF01-2FE2-2334-0D35-9CCD078F529C")
    private static let shellNotify = CBUUID(string: "77D4FF02-2FE2-2334-0D35-9CCD078F529C")

    private static let msg: UInt16 = 0x90A5
    private static let ping: UInt16 = 0x90A7
    private static let event: UInt16 = 0xB0A6
    /// Reply opcodes: the request's opcode with `0xA000` set.
    private static let msgReply: UInt16 = 0xB0A5
    private static let pingReply: UInt16 = 0xB0A7

    @Published private(set) var state: State = .off
    @Published private(set) var watchName: String?
    /// The last thing that went wrong while talking to the app, shown under the link status.
    @Published private(set) var lastProblem: String?

    /// The row names to push, read when the watch asks for them.
    var names: () -> [String] = { [] }
    /// Called on the main actor for every decoded event.
    var onEvent: ((WatchEvent) -> Void)?

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var commandWriteChar: CBCharacteristic?
    private var shellWriteChar: CBCharacteristic?
    private var parser = FrameParser()
    private var key: [UInt8]?
    private var shellReply = ""
    private var readingSecret = false
    private var wantsConnection = false
    private var keepAlive: Task<Void, Never>?

    /// One message at a time, because the watch's inbox holds four; `Outbox` holds the ordering rules.
    private var outbox = Outbox()
    /// Bumped whenever the link is reset, so a stale watchdog cannot resend over a new link.
    private var generation = 0
    /// The stored key opened at least one PING reply on this link, so it is the watch's current secret.
    private var keyWorks = false
    /// PING replies the key could not open, counted up to 2 before the secret is read again.
    private var failedOpens = 0
    /// `true` once a notification subscription was reported, per characteristic.
    private var notify: [CBUUID: Bool] = [:]
    /// The session started: guards against starting it twice while both services report in.
    private var talking = false

    // MARK: - Public

    func start() {
        wantsConnection = true
        guard let central else {
            central = CBCentralManager(delegate: self, queue: .main)
            return
        }
        if central.state == .poweredOn { findWatch(central) }
    }

    func stop() {
        wantsConnection = false
        keepAlive?.cancel()
        keepAlive = nil
        if let peripheral, let central { central.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        key = nil
        watchName = nil
        outbox.clear()
        generation &+= 1
        talking = false
        notify = [:]
        state = .off
    }

    /// Reads `AT GETSECRET` again, e.g. after a factory reset changed it.
    func forgetSecret() {
        key = nil
        outbox.clear()
        SecretStore.clear()
        readSecret()
    }

    /// Sends one `h1` message to the running app, after the ones already queued.
    func send(_ message: [UInt8]) {
        outbox.push([message], replacing: false)
        pump()
    }

    /// The whole list as `L`…`E`, one message per row, each inside the watch's 128 B.
    func answer() {
        let names = names()
        guard !names.isEmpty else { return }
        var messages = [H1.begin(names.count)]
        for (index, name) in names.enumerated() { messages.append(H1.slot(index, name: name)) }
        messages.append(H1.end(names.count))
        // A new list replaces the old one; whatever was queued is now wrong.
        outbox.push(messages, replacing: true)
        pump()
    }

    /// Writes the next queued message if the link is idle; the watch's reply to it drives the next one.
    private func pump() {
        guard let key, let commandWriteChar, let peripheral else {
            outbox.clear()
            return
        }
        guard let message = outbox.next() else { return }
        generation &+= 1
        let sealed = Frame.build(c1: Frame.system, c2: Self.msg, payload: [0xFF] + message, key: key)
        peripheral.writeValue(Data(sealed), for: commandWriteChar, type: .withResponse)
        watchReply(after: 3)
    }

    /// Puts the message in flight back at the head when no reply arrives: a lost notification must not stall
    /// the queue, and a sender that stops answering must not leave the UI saying "Sending" forever.
    private func watchReply(after seconds: Double) {
        let issued = generation
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, self.generation == issued else { return }
            if self.outbox.timedOut() == .gaveUp { self.lastProblem = "The watch stopped answering" }
            self.pump()
        }
    }

    /// The watch replied to the message in flight.
    private func acknowledged(_ status: UInt8?) {
        switch outbox.settle(status: status) {
        case .accepted:
            lastProblem = nil
            pump()
        case .retry:
            // Busy or full: the same message goes again once the watch has taken the ones before it.
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(120))
                self?.pump()
            }
        case .refused(let code):
            lastProblem = code == 7 ? "The watch app is not open" : "The watch refused a message (\(code))"
        case .gaveUp:
            lastProblem = "The watch stopped answering"
        }
    }

    // MARK: - Link

    private static let watchNamePrefixes = ["cmf watch", "nothing watch", "cmf watch pro"]

    private func findWatch(_ central: CBCentralManager) {
        // Nothing X holds the link; ask for that peripheral rather than competing with it.
        let connected = central.retrieveConnectedPeripherals(withServices: [Self.commandService])
        if let watch = connected.first {
            connect(watch, central)
            return
        }
        // Do not filter the scan by FFF0: the watch does not advertise that service reliably, and CoreBluetooth
        // then never reports it. The Python host scans all peripherals and matches on the name; do the same.
        state = .scanning
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    private func isWatch(_ peripheral: CBPeripheral, advertisementData: [String: Any]) -> Bool {
        let local = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = local ?? peripheral.name ?? ""
        let lowered = name.lowercased()
        return Self.watchNamePrefixes.contains { lowered.contains($0) }
    }

    private func connect(_ watch: CBPeripheral, _ central: CBCentralManager) {
        state = .connecting
        watchName = watch.name
        // A peripheral from `retrieveConnectedPeripherals` is already connected: `didConnect` never fires, so set up
        // the delegate and discover here. Otherwise `didConnect` does it.
        if watch.state == .connected {
            self.peripheral = watch
            watch.delegate = self
            watch.discoverServices([Self.commandService, Self.shellService])
        } else {
            central.connect(watch, options: nil)
        }
    }

    private func readSecret() {
        guard let shellWriteChar, let peripheral else {
            state = .failed("The watch has no shell service; is the patched firmware installed?")
            return
        }
        shellReply = ""
        readingSecret = true
        state = .readingSecret
        peripheral.writeValue(Data("AT GETSECRET\r\n".utf8), for: shellWriteChar, type: .withResponse)
    }

    /// One `PING` registers this host: from then on the watch pushes events instead of waiting to be polled.
    /// Some loaders only push while a host frame is recent, so a slow PING keeps it that way (cheap: 20 bytes).
    private func hello() {
        state = .ready
        onEvent?(.linked)
        ping()
        keepAlive?.cancel()
        keepAlive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled, let self else { return }
                self.ping()
            }
        }
    }

    private func ping() {
        guard let key, let commandWriteChar, let peripheral else { return }
        let frame = Frame.build(c1: Frame.system, c2: Self.ping, payload: [0x00], key: key)
        peripheral.writeValue(Data(frame), for: commandWriteChar, type: .withResponse)
    }

    private func handleFrames(_ frames: [(c1: UInt16, c2: UInt16, body: [UInt8])]) {
        for frame in frames where frame.c1 == Frame.system {
            switch frame.c2 {
            case Self.event:
                guard let key, let plain = open(frame.body, key: key), plain.count >= 2 else { continue }
                // `seq ‖ slot ‖ data`; `seq` only tells the phone about gaps, which do not matter for `h1`.
                receive(Array(plain.dropFirst(2)))
            case Self.msgReply:
                acknowledged(frame.body.first)
            case Self.pingReply:
                // The reply is sealed with the same K, so a key that cannot open it is stale (a factory reset
                // changed the secret). Opening it once is enough to know the key is right.
                guard let key else { continue }
                if open(frame.body, key: key) != nil {
                    keyWorks = true
                    lastProblem = nil
                } else if !keyWorks {
                    failedOpens += 1
                    if failedOpens >= 2 {
                        failedOpens = 0
                        SecretStore.clear()
                        readSecret()
                    }
                }
            default:
                break
            }
        }
    }

    private func receive(_ data: [UInt8]) {
        if data == H1.ask {
            onEvent?(.asked)
        } else if let row = H1.run(data) {
            onEvent?(.run(row: row))
        }
    }

    private func takeSecret() {
        let reply = shellReply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = reply.firstIndex(of: ":"), let comma = reply.lastIndex(of: ","),
              let secret = [UInt8](hex: String(reply[reply.index(after: colon)..<comma])),
              secret.count == 16
        else {
            state = .failed("The watch did not answer AT GETSECRET")
            return
        }
        key = secret
        keyWorks = false
        failedOpens = 0
        SecretStore.save(secret)
        hello()
    }
}

// MARK: - CBCentralManagerDelegate

extension WatchLink: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            guard self.wantsConnection else { return }
            switch central.state {
            case .poweredOn: self.findWatch(central)
            case .unauthorized: self.state = .failed("Bluetooth permission is off for this app")
            case .poweredOff: self.state = .failed("Turn Bluetooth on")
            default: self.state = .off
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi RSSI: NSNumber
    ) {
        Task { @MainActor in
            guard self.wantsConnection else { return }
            // Scanning unfiltered reports every BLE device: connect only to a watch, not a random peripheral.
            guard self.isWatch(peripheral, advertisementData: advertisementData) else { return }
            central.stopScan()
            self.connect(peripheral, central)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            self.peripheral = peripheral
            self.watchName = peripheral.name ?? self.watchName
            peripheral.delegate = self
            peripheral.discoverServices([Self.commandService, Self.shellService])
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?
    ) {
        Task { @MainActor in
            self.state = .failed(error?.localizedDescription ?? "Could not connect")
            guard self.wantsConnection else { return }
            try? await Task.sleep(for: .seconds(2))
            guard self.wantsConnection else { return }
            self.findWatch(central)
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?
    ) {
        Task { @MainActor in
            self.peripheral = nil
            self.commandWriteChar = nil
            self.shellWriteChar = nil
            self.parser = FrameParser()
            self.notify = [:]
            self.talking = false
            self.outbox.clear()
            self.generation &+= 1
            self.keyWorks = false
            self.failedOpens = 0
            self.keepAlive?.cancel()
            self.keepAlive = nil
            self.onEvent?(.lost)
            guard self.wantsConnection else { return }
            self.state = .connecting
            central.connect(peripheral, options: nil)
        }
    }
}

// MARK: - CBPeripheralDelegate

extension WatchLink: CBPeripheralDelegate {
    /// CoreBluetooth calls this after `discoverServices`; without it `discoverCharacteristics` is never issued and
    /// the write/notify characteristics stay unknown, so the link never starts (the two sides "don't see" each other).
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            guard let services = peripheral.services, error == nil else {
                self.state = .failed("Could not discover the watch's services")
                return
            }
            for service in services where [Self.commandService, Self.shellService].contains(service.uuid) {
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?
    ) {
        Task { @MainActor in
            for characteristic in service.characteristics ?? [] {
                switch characteristic.uuid {
                case Self.commandWrite:
                    self.commandWriteChar = characteristic
                case Self.shellWrite:
                    self.shellWriteChar = characteristic
                default:
                    // The two notify characteristics are subscribed by uuid; the rest is not used.
                    if [Self.commandNotify, Self.shellNotify].contains(characteristic.uuid) {
                        self.notify[characteristic.uuid] = false
                        peripheral.setNotifyValue(true, for: characteristic)
                    }
                }
            }
            self.startTalking()
        }
    }

    /// Starts the session once the write characteristics are known and `FFF1` really notifies, so the first
    /// reply (the PING's) is not lost to a subscription that was still being set up.
    private func startTalking() {
        guard shellWriteChar != nil, commandWriteChar != nil, notify[Self.commandNotify] == true else { return }
        guard !talking else { return }
        talking = true
        if let cached = SecretStore.load() {
            key = cached
            hello()
        } else {
            readSecret()
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?
    ) {
        Task { @MainActor in
            self.notify[characteristic.uuid] = characteristic.isNotifying && error == nil
            self.startTalking()
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?
    ) {
        Task { @MainActor in
            guard let data = characteristic.value else { return }
            if characteristic.uuid == Self.shellNotify {
                self.shellReply += String(decoding: data, as: UTF8.self)
                if self.readingSecret,
                   self.shellReply.contains("OK") || self.shellReply.contains("ERROR")
                        || self.shellReply.contains("FAIL") {
                    self.readingSecret = false
                    self.takeSecret()
                }
                return
            }
            self.handleFrames(self.parser.feed(Array(data)))
        }
    }
}

/// The pairing secret is personal data: it opens the watch's channel. Keychain, never `UserDefaults`.
enum SecretStore {
    private static let service = "fmc.shortcuts"
    private static let account = "watch.pairing-secret"

    private static var base: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func load() -> [UInt8]? {
        var query = base
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, data.count == 16
        else { return nil }
        return Array(data)
    }

    static func save(_ secret: [UInt8]) {
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(secret)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func clear() {
        SecItemDelete(base as CFDictionary)
    }
}

extension Array where Element == UInt8 {
    /// `"00a1…"` → bytes; `nil` on an odd length or a non-hex digit.
    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = bytes
    }
}
