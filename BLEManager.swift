//
//  BLEManager.swift
//  LactateExpress
//
//  Created by eagle on 2026/4/14.
//

import Combine
import CoreBluetooth
import Foundation

final class BLEManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let shared = BLEManager()
    private let activationStorageKey = "DeviceActivationTimes"
    private let lastSeqStorageKey = "DeviceLastSeqs"
    private let historyDirectoryName = "LactateHistory"
    private let historyIndexStorageKey = "LactateHistoryDeviceUUIDs"
    private let legacyHistoryStorageKey = "LactateHistoryData"
    private let historyQueue = DispatchQueue(label: "de.copatec.LactateExpress.historyQueue", qos: .utility)
    private let targetServiceUUID = CBUUID(string: "8653000A-43E6-47B7-9CB0-5FC21D4AE340")
    private let notifyCharUUID = CBUUID(string: "8653000B-43E6-47B7-9CB0-5FC21D4AE340")
    private let writeCharUUID = CBUUID(string: "8653000C-43E6-47B7-9CB0-5FC21D4AE340")
    @Published var status = "Waiting Bluetooth"
    @Published var lactate = "0.00 mmol/L"
    @Published var rawData = "Waiting data..."
    @Published var historyData: [DataPoint] = []
    @Published var foundDevices: [CBPeripheral] = []
    @Published var connectedPeripheralUUID: String?
    @Published var connectedPeripheralName: String?
    private var central: CBCentralManager!
    private var notifyPeripheral: CBPeripheral?
    private var notifyCharacteristic: CBCharacteristic?
    private var writeCharacteristic: CBCharacteristic?
    private var activationTimes: [String: Date] = [:] { didSet { saveActivationTimes() } }
    private var lastSeqs: [String: Int] = [:] { didSet { saveLastSeqs() } }
    private var deviceUUIDIndex: Set<String> = [] { didSet { saveDeviceUUIDIndex() } }
    private var didTriggerInitialSyncForCurrentConnection = false
    private var isBackfillingHistory = false
    private var backfillStartSeq: Int?
    private var backfillTargetSeq: Int?
    private var lastRequestedHistorySeq: Int?
    private var lastReceivedHistorySeq: Int?
    private var backfillRetryCount = 0
    private let maxBackfillRetryCount = 3

    override init() {
        super.init()
        removeLegacyHistoryBlobIfNeeded()
        central = CBCentralManager(delegate: self, queue: .main)
        loadActivationTimes()
        loadLastSeqs()
        loadDeviceUUIDIndex()
        loadHistoryFromFilesAsync()
    }
    func getAvailableDevices() -> [(uuid: String, name: String)] {
        Dictionary(grouping: historyData, by: \.deviceUUID).compactMap {
            $0.value.first.map { ($0.deviceUUID, $0.deviceName) }
        }
    }
    func nextMissingSeq(for deviceUUID: String) -> Int? {
        let seqs = historyData.filter { $0.deviceUUID == deviceUUID }.compactMap(\.seq).sorted()
        guard !seqs.isEmpty else { return nil }
        for idx in 1 ..< seqs.count where seqs[idx] > seqs[idx - 1] + 1 { return seqs[idx - 1] + 1 }
        return (seqs.last ?? 0) + 1
    }
    func clearHistoryForConnectedDevice() {
        guard let deviceUUID = connectedPeripheralUUID else { return }
        historyData.removeAll { $0.deviceUUID == deviceUUID }
        lastSeqs.removeValue(forKey: deviceUUID)
        activationTimes.removeValue(forKey: deviceUUID)
        deviceUUIDIndex.remove(deviceUUID)
        saveHistoryForDeviceAsync(deviceUUID)
        lactate = "0.00 mmol/L"
        rawData = "Waiting data..."
        status = "History cleared for current device"
        isBackfillingHistory = false
        backfillStartSeq = nil
        backfillTargetSeq = nil
        lastRequestedHistorySeq = nil
        lastReceivedHistorySeq = nil
        backfillRetryCount = 0
    }
    func activationTimeForConnectedDevice() -> Date? { connectedPeripheralUUID.flatMap { activationTimes[$0] } }
    func setActivationTimeForConnectedDevice(_ date: Date) {
        guard let deviceUUID = connectedPeripheralUUID else { return }
        activationTimes[deviceUUID] = date
        if let deviceName = connectedPeripheralName { recomputeTimestamps(for: deviceUUID, deviceName: deviceName) }
        saveHistoryForDeviceAsync(deviceUUID)
        status = "Activation time updated"
    }
    private func firstMissingSeq(in sortedSeqs: [Int]) -> Int? {
        guard !sortedSeqs.isEmpty else { return nil }
        for idx in 1 ..< sortedSeqs.count where sortedSeqs[idx] > sortedSeqs[idx - 1] + 1 { return sortedSeqs[idx - 1] + 1 }
        return nil
    }
    private func latestKnownSeq(for deviceUUID: String) -> Int? { historyData.filter { $0.deviceUUID == deviceUUID }.compactMap(\.seq).max() }
    private func maxStoredSeq(for deviceUUID: String, excluding seqToIgnore: Int?) -> Int? {
        historyData.filter { item in
            guard item.deviceUUID == deviceUUID, let seq = item.seq else { return false }
            return seqToIgnore.map { seq != $0 } ?? true
        }
        .compactMap(\.seq)
        .max()
    }
    private func removeLegacyHistoryBlobIfNeeded() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: legacyHistoryStorageKey) != nil { defaults.removeObject(forKey: legacyHistoryStorageKey) }
    }
    private func historyDirectoryURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent(historyDirectoryName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }
    private func historyFileURL(for deviceUUID: String) -> URL {
        let safe = deviceUUID.replacingOccurrences(of: "/", with: "_")
        return historyDirectoryURL().appendingPathComponent("\(safe).json")
    }
    private func saveDeviceUUIDIndex() { UserDefaults.standard.set(Array(deviceUUIDIndex).sorted(), forKey: historyIndexStorageKey) }
    private func loadDeviceUUIDIndex() { deviceUUIDIndex = Set(UserDefaults.standard.stringArray(forKey: historyIndexStorageKey) ?? []) }
    private func loadHistoryFromFilesAsync() {
        historyQueue.async {
            var loaded: [DataPoint] = []
            for uuid in self.deviceUUIDIndex {
                let url = self.historyFileURL(for: uuid)
                guard let data = try? Data(contentsOf: url),
                      let arr = try? JSONDecoder().decode([DataPoint].self, from: data) else { continue }
                loaded.append(contentsOf: arr)
            }
            loaded.sort { $0.timestamp < $1.timestamp }
            var rebuiltLastSeqs = self.lastSeqs
            for item in loaded {
                guard let seq = item.seq else { continue }
                rebuiltLastSeqs[item.deviceUUID] = max(rebuiltLastSeqs[item.deviceUUID] ?? seq, seq)
            }
            DispatchQueue.main.async {
                self.historyData = loaded
                self.lastSeqs = rebuiltLastSeqs
                self.status = self.status == "Waiting Bluetooth" ? "Bluetooth cache loaded" : self.status
            }
        }
    }
    private func saveHistoryForDeviceAsync(_ deviceUUID: String) {
        let devicePoints = historyData.filter { $0.deviceUUID == deviceUUID }.sorted { $0.timestamp < $1.timestamp }
        let url = historyFileURL(for: deviceUUID)
        historyQueue.async {
            if devicePoints.isEmpty { try? FileManager.default.removeItem(at: url); return }
            guard let data = try? JSONEncoder().encode(devicePoints) else { return }
            try? data.write(to: url, options: [.atomic])
        }
    }
    private func saveActivationTimes() {
        UserDefaults.standard.set(activationTimes.mapValues { $0.timeIntervalSince1970 }, forKey: activationStorageKey)
    }
    private func loadActivationTimes() {
        guard let dict = UserDefaults.standard.dictionary(forKey: activationStorageKey) as? [String: TimeInterval] else { return }
        activationTimes = dict.mapValues { Date(timeIntervalSince1970: $0) }
    }
    private func saveLastSeqs() { UserDefaults.standard.set(lastSeqs, forKey: lastSeqStorageKey) }
    private func loadLastSeqs() { if let dict = UserDefaults.standard.dictionary(forKey: lastSeqStorageKey) as? [String: Int] { lastSeqs = dict } }
    func startScan() {
        foundDevices.removeAll()
        status = "Scanning..."
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }
    func connect(_ peripheral: CBPeripheral) {
        central.stopScan()
        connectedPeripheralUUID = peripheral.identifier.uuidString
        connectedPeripheralName = peripheral.name ?? "Device"
        status = "Connecting: \(peripheral.name ?? "Device")"
        notifyPeripheral = peripheral
        notifyPeripheral?.delegate = self
        notifyCharacteristic = nil
        writeCharacteristic = nil
        didTriggerInitialSyncForCurrentConnection = false
        central.connect(peripheral)
    }
    func manualSyncHistory(startSeq: Int? = nil) {
        guard notifyPeripheral != nil, writeCharacteristic != nil else { status = "Sync failed: write channel not ready"; return }
        guard let deviceUUID = connectedPeripheralUUID else { return }
        let beginSeq = startSeq ?? nextMissingSeq(for: deviceUUID) ?? ((latestKnownSeq(for: deviceUUID) ?? -1) + 1)
        backfillStartSeq = beginSeq
        backfillTargetSeq = latestKnownSeq(for: deviceUUID)
        isBackfillingHistory = true
        lastRequestedHistorySeq = nil
        lastReceivedHistorySeq = nil
        backfillRetryCount = 0
        status = "Manual history sync..."
        sendSetTime()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.requestHistoryPage(from: beginSeq) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.sendHistoryStreamStart() }
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        status = central.state == .poweredOn ? "Bluetooth ON → Ready" : "Bluetooth NOT Available"
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard let name = peripheral.name, !name.isEmpty, name.starts(with: "Eaglenos") else { return }
        if !foundDevices.contains(where: { $0.identifier == peripheral.identifier }) { foundDevices.append(peripheral) }
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        status = "Connected: \(peripheral.name ?? "Device")"
        peripheral.discoverServices([targetServiceUUID])
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if connectedPeripheralUUID == peripheral.identifier.uuidString {
            connectedPeripheralUUID = nil; connectedPeripheralName = nil
            notifyPeripheral = nil; notifyCharacteristic = nil; writeCharacteristic = nil
            didTriggerInitialSyncForCurrentConnection = false; isBackfillingHistory = false
        }
        status = error == nil ? "Disconnected" : "Disconnected → Please reconnect"
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { status = "Discover services error: \(error.localizedDescription)"; return }
        guard let services = peripheral.services else { return }
        for service in services where service.uuid == targetServiceUUID {
            peripheral.discoverCharacteristics([notifyCharUUID, writeCharUUID], for: service)
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { status = "Discover chars error: \(error.localizedDescription)"; return }
        guard let chars = service.characteristics else { return }
        for char in chars {
            if char.uuid == notifyCharUUID { notifyCharacteristic = char; peripheral.setNotifyValue(true, for: char) }
            if char.uuid == writeCharUUID { writeCharacteristic = char }
        }
        triggerInitialHistorySyncIfReady()
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error { status = "Notify failed: \(error.localizedDescription)"; return }
        status = characteristic.isNotifying ? "Notify ON" : "Notify OFF"
        triggerInitialHistorySyncIfReady()
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { status = "Write failed: \(error.localizedDescription)" }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, characteristic.uuid == notifyCharacteristic?.uuid, let data = characteristic.value else { return }
        let byteArray = [UInt8](data)
        rawData = byteArray.map { String(format: "%02x ", $0) }.joined()
        let fullDeviceName = peripheral.name ?? "Unknown Device"
        let deviceUUID = peripheral.identifier.uuidString
        if isHistoryPacket(byteArray) {
            handleHistoryPacket(byteArray, deviceName: fullDeviceName, deviceUUID: deviceUUID)
        } else if isRealtimePacket(byteArray) {
            handleRealtimePacket(byteArray, deviceName: fullDeviceName, deviceUUID: deviceUUID)
        }
    }
    private func isHistoryPacket(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 6, bytes[0] == 0xEB, bytes[1] == 0x90 else { return false }
        let type = Int(bytes[2]) << 8 | Int(bytes[3])
        let len = Int(bytes[4]) << 8 | Int(bytes[5])
        return type == 0x0004 && (len == 0x00D9 || len == 0x0039)
    }
    private func isRealtimePacket(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 6, bytes[0] == 0xEB, bytes[1] == 0x90, bytes[2] == 0x00,
              bytes[4] == 0x00, bytes[5] == 0x19, bytes[6] == 0x09 else { return false }
        return (Int(bytes[4]) << 8 | Int(bytes[5])) == 0x0019
    }
    private func handleRealtimePacket(_ bytes: [UInt8], deviceName: String, deviceUUID: String) {
        guard bytes.count >= 11 else { return }
        let rawVal = Int(bytes[7]) * 256 + Int(bytes[8])
        let value = Float(rawVal) / 100.0
        let seq = parseRealtimeSeq(from: bytes)
        let previousMaxSeq = maxStoredSeq(for: deviceUUID, excluding: seq)
        DispatchQueue.main.async {
            self.connectedPeripheralUUID = deviceUUID
            self.connectedPeripheralName = deviceName
            self.lactate = String(format: "%.2f mmol/L", value)
            self.status = "Receiving realtime data..."
            if self.activationTimes[deviceUUID] == nil, let seq {
                let interval = self.deviceInterval(for: deviceName)
                self.activationTimes[deviceUUID] = Date().addingTimeInterval(-TimeInterval(seq) * interval.secondsPerSample)
                self.recomputeTimestamps(for: deviceUUID, deviceName: deviceName)
            }
            let timestamp = self.computeTimestamp(deviceUUID: deviceUUID, deviceName: deviceName, receiveTime: Date(), seq: seq)
            self.upsert(DataPoint(value: value, timestamp: timestamp, deviceName: deviceName, deviceUUID: deviceUUID, seq: seq))
            self.requestMissingHistoryIfNeeded(for: deviceUUID, realtimeSeq: seq, previousMaxSeq: previousMaxSeq)
        }
    }
    private func handleHistoryPacket(_ bytes: [UInt8], deviceName: String, deviceUUID: String) {
        guard bytes.count > 13 else { return }
        let payload = Array(bytes.dropFirst(6).dropLast(4))
        guard payload.count > 3 else { return }
        let body = Array(payload.dropFirst(3))
        let recordSize = 16
        let recordCount = body.count / recordSize
        guard recordCount > 0 else { return }
        var points: [DataPoint] = []
        for idx in 0 ..< recordCount {
            let start = idx * recordSize
            let rec = Array(body[start ..< (start + recordSize)])
            let seq = Int(rec[0]) * 256 + Int(rec[1])
            let rawValue = Int(rec[14]) * 256 + Int(rec[15])
            let value = Float(rawValue) / 100.0
            let timestamp = computeTimestamp(deviceUUID: deviceUUID, deviceName: deviceName, receiveTime: Date(), seq: seq)
            points.append(DataPoint(value: value, timestamp: timestamp, deviceName: deviceName, deviceUUID: deviceUUID, seq: seq))
        }
        let pageMaxSeq = points.compactMap(\.seq).max()
        DispatchQueue.main.async {
            self.connectedPeripheralUUID = deviceUUID
            self.connectedPeripheralName = deviceName
            self.status = "Receiving history data..."
            for point in points { self.upsert(point) }
            guard self.isBackfillingHistory else { return }
            guard let pageMaxSeq else { self.isBackfillingHistory = false; self.status = "History sync stopped"; return }
            if let lastRequested = self.lastRequestedHistorySeq, pageMaxSeq < lastRequested {
                self.backfillRetryCount += 1
                if self.backfillRetryCount > self.maxBackfillRetryCount {
                    self.isBackfillingHistory = false; self.status = "History sync stopped"; return
                }
                self.requestHistoryPage(from: lastRequested)
                return
            }
            self.backfillRetryCount = 0
            self.lastReceivedHistorySeq = pageMaxSeq
            if let target = self.backfillTargetSeq, pageMaxSeq < target {
                self.requestHistoryPage(from: pageMaxSeq + 1)
            } else {
                self.isBackfillingHistory = false
                self.status = "History sync completed"
            }
        }
    }
    private func upsert(_ point: DataPoint) {
        let deviceUUID = point.deviceUUID
        if let seq = point.seq, let idx = historyData.firstIndex(where: { $0.deviceUUID == deviceUUID && $0.seq == seq }) {
            historyData[idx] = point
        } else {
            historyData.append(point)
        }
        deviceUUIDIndex.insert(deviceUUID)
        saveHistoryForDeviceAsync(deviceUUID)
        if let seq = point.seq { lastSeqs[deviceUUID] = max(lastSeqs[deviceUUID] ?? seq, seq) }
    }
    private func requestMissingHistoryIfNeeded(for deviceUUID: String, realtimeSeq: Int?, previousMaxSeq: Int?) {
        guard !isBackfillingHistory, let realtimeSeq, let previousMaxSeq, realtimeSeq > previousMaxSeq + 1 else { return }
        let missingStartSeq = previousMaxSeq + 1
        status = "Realtime gap detected, syncing history from seq \(missingStartSeq)"
        manualSyncHistory(startSeq: missingStartSeq)
    }
    private func requestHistoryPage(from startSeq: Int) {
        lastRequestedHistorySeq = startSeq
        sendHistoryRequest(startSeqOverride: startSeq)
    }
    private func triggerInitialHistorySyncIfReady() {
        guard !didTriggerInitialSyncForCurrentConnection,
              let peripheral = notifyPeripheral,
              let notifyCharacteristic,
              let writeCharacteristic,
              notifyCharacteristic.isNotifying,
              peripheral.state == .connected else {
            return
        }
        _ = writeCharacteristic
        didTriggerInitialSyncForCurrentConnection = true
        status = "Connected and ready"
    }
    private func sendSetTime() {
        guard let peripheral = notifyPeripheral, let writeCharacteristic else { return }
        peripheral.writeValue(Data(buildSetTimePacket(date: Date())), for: writeCharacteristic, type: .withResponse)
    }
    private func sendHistoryRequest(startSeqOverride: Int?) {
        guard let peripheral = notifyPeripheral, let writeCharacteristic, let deviceUUID = connectedPeripheralUUID else { return }
        let startSeq: Int
        if let startSeqOverride {
            startSeq = startSeqOverride & 0xFFFF
        } else if let last = lastSeqs[deviceUUID] {
            startSeq = (last + 1) & 0xFFFF
        } else {
            startSeq = 0
        }
        peripheral.writeValue(Data(buildHistoryRequestPacket(startSeq: startSeq)), for: writeCharacteristic, type: .withResponse)
    }
    private func sendHistoryStreamStart() {
        guard let peripheral = notifyPeripheral, let writeCharacteristic else { return }
        peripheral.writeValue(Data(buildHistoryStreamStartPacket()), for: writeCharacteristic, type: .withResponse)
    }
    private func buildSetTimePacket(date: Date) -> [UInt8] {
        let cal = Calendar(identifier: .gregorian)
        let year = cal.component(.year, from: date)
        let month = cal.component(.month, from: date)
        let day = cal.component(.day, from: date)
        let hour = cal.component(.hour, from: date)
        let minute = cal.component(.minute, from: date)
        let second = cal.component(.second, from: date)
        var payload: [UInt8] = [
            0xEB, 0x90, 0x00, 0x03, 0x00, 0x13, 0x01, 0x00, 0x00, 0x00,
            UInt8((year >> 8) & 0xFF), UInt8(year & 0xFF), UInt8(month & 0xFF), UInt8(day & 0xFF),
            UInt8(hour & 0xFF), UInt8(minute & 0xFF), UInt8(second & 0xFF), 0x00,
        ]
        let sum = checksum16(payload)
        payload.append(UInt8((sum >> 8) & 0xFF)); payload.append(UInt8(sum & 0xFF))
        payload.append(0x0D); payload.append(0x0A)
        return payload
    }
    private func buildHistoryRequestPacket(startSeq: Int) -> [UInt8] {
        var payload: [UInt8] = [
            0xEB, 0x90, 0x00, 0x04, 0x00, 0x0D, 0x07, 0x00, 0x00,
            UInt8((startSeq >> 8) & 0xFF), UInt8(startSeq & 0xFF),
        ]
        let sum = checksum16(payload)
        payload.append(UInt8((sum >> 8) & 0xFF)); payload.append(UInt8(sum & 0xFF))
        payload.append(0x0D); payload.append(0x0A)
        return payload
    }
    private func buildHistoryStreamStartPacket() -> [UInt8] {
        var payload: [UInt8] = [0xEB, 0x90, 0x00, 0x06, 0x00, 0x0D, 0x07, 0x00, 0x00, 0x00, 0x01]
        let sum = checksum16(payload)
        payload.append(UInt8((sum >> 8) & 0xFF)); payload.append(UInt8(sum & 0xFF))
        payload.append(0x0D); payload.append(0x0A)
        return payload
    }
    private func checksum16(_ bytes: [UInt8]) -> UInt16 { bytes.reduce(0) { ($0 + UInt16($1)) & 0xFFFF } }
    private func deviceInterval(for deviceName: String) -> DeviceSampleInterval {
        let upper = deviceName.uppercased()
        if upper.contains("CLM") { return .lactate1min }
        if upper.contains("CGM") { return .glucose3min }
        let lower = deviceName.lowercased()
        if lower.contains("lac") || lower.contains("lact") { return .lactate1min }
        return .glucose3min
    }
    private func computeTimestamp(deviceUUID: String, deviceName: String, receiveTime: Date, seq: Int?) -> Date {
        guard let seq, let activation = activationTimes[deviceUUID] else { return receiveTime }
        return activation.addingTimeInterval(TimeInterval(seq) * deviceInterval(for: deviceName).secondsPerSample)
    }
    private func recomputeTimestamps(for deviceUUID: String, deviceName: String) {
        guard let activation = activationTimes[deviceUUID] else { return }
        let interval = deviceInterval(for: deviceName)
        for idx in historyData.indices where historyData[idx].deviceUUID == deviceUUID {
            guard let seq = historyData[idx].seq else { continue }
            historyData[idx].timestamp = activation.addingTimeInterval(TimeInterval(seq) * interval.secondsPerSample)
        }
    }
    private func parseRealtimeSeq(from bytes: [UInt8]) -> Int? {
        guard isRealtimePacket(bytes), bytes.count >= 11 else { return nil }
        return Int(bytes[9]) * 256 + Int(bytes[10])
    }
}
