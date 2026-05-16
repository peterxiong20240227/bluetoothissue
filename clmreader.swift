//
//  ClmReader.swift
//  LactateExpress
//
//  Created by eagle on 2026/4/14.
//

import Charts
import Combine
import CoreBluetooth
import Foundation
import SwiftUI
import UIKit

struct ClmReader: View {
    @StateObject private var ble = BLEManager.shared
    @State private var showExportSheet = false
    @State private var showDeviceList = false
    @State private var startDate = Date()
    @State private var endDate = Date()
    @State private var selectedDeviceUUID: String?
    @State private var shouldExportAfterDismiss = false

    @State private var chartStartDate = Date().addingTimeInterval(-86400 * 7)
    @State private var chartEndDate = Date()
    @State private var showChartTimePicker = false

    @State private var endPinned = false

    @State private var displayData: [DataPoint] = []

    private var chartYRange: ClosedRange<Float> {
        let values = displayData.map { $0.value }
        guard !values.isEmpty else { return 0...10 }
        let maxVal = values.max() ?? 10
        return 0...(maxVal + 1)
    }

    var body: some View {
        VStack(spacing: 12) {
            TopControlView(ble: ble, showExportSheet: $showExportSheet, showDeviceList: $showDeviceList)

            Text(ble.lactate)
                .font(.system(size: 48, weight: .bold))
                .foregroundColor(.green)

            if ble.connectedPeripheralUUID != nil {
                HStack(spacing: 10) {
                    Button {
                        ble.manualSyncHistory()
                    } label: {
                        Text("Sync History")
                            .font(.subheadline)
                            .foregroundColor(.white)
                            .padding(6)
                            .background(Color.purple)
                            .cornerRadius(8)
                    }

                    Button {
                        ble.toggleRawSendPanel()
                    } label: {
                        Text("Send Raw")
                            .font(.subheadline)
                            .foregroundColor(.white)
                            .padding(6)
                            .background(Color.gray)
                            .cornerRadius(8)
                    }
                }

                if ble.showRawSendPanel {
                    VStack(spacing: 8) {
                        Text("Raw Hex (spaces ok, no 0x prefix)")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        TextField("e.g. eb 90 00 04 ... 0d 0a", text: $ble.rawHexToSend)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))

                        HStack(spacing: 10) {
                            Button("Send") {
                                ble.sendRawHexFromUI()
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.black)
                            .foregroundColor(.white)
                            .cornerRadius(8)

                            Button("Fill: History startSeq=0") {
                                ble.fillRawHexHistoryStart0()
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                        }
                    }
                    .padding(.horizontal)
                }

                Button {
                    showChartTimePicker = true
                } label: {
                    Text("Select Chart Time Range")
                        .font(.subheadline)
                        .foregroundColor(.white)
                        .padding(6)
                        .background(Color.blue)
                        .cornerRadius(8)
                }

                Button {
                    endPinned = false
                    rebuildDisplayData()
                } label: {
                    Text("Live Mode (No End Limit)")
                        .font(.subheadline)
                        .foregroundColor(.white)
                        .padding(6)
                        .background(Color.orange)
                        .cornerRadius(8)
                }
            }

            if ble.connectedPeripheralUUID == nil {
                Text("No device connected. Please scan and select a device.")
                    .foregroundColor(.gray)
                    .frame(height: 200)
                    .padding(.horizontal)
            } else {
                if !displayData.isEmpty {
                    LactateChartView(data: displayData, yRange: chartYRange)
                } else {
                    Text("No chart data in selected range")
                        .foregroundColor(.gray)
                        .frame(height: 200)
                }

                LactateTableView(data: displayData)
            }

            Spacer()
        }
        .navigationTitle("CLM Sensor")
        .sheet(isPresented: $showDeviceList) {
            DeviceListView(ble: ble, isPresented: $showDeviceList)
        }
        .sheet(isPresented: $showExportSheet) {
            ExportFilterView(
                startDate: $startDate,
                endDate: $endDate,
                selectedDeviceUUID: $selectedDeviceUUID,
                allDevices: ble.getAvailableDevices(),
                onExport: {
                    shouldExportAfterDismiss = true
                    showExportSheet = false
                },
                onCancel: {
                    shouldExportAfterDismiss = false
                    showExportSheet = false
                }
            )
        }
        .sheet(isPresented: $showChartTimePicker) {
            NavigationStack {
                List {
                    DatePicker("Chart Start Time", selection: $chartStartDate, displayedComponents: [.date, .hourAndMinute])
                    DatePicker("Chart End Time", selection: $chartEndDate, displayedComponents: [.date, .hourAndMinute])
                }
                .navigationTitle("Chart Time Filter")
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Reset Live") {
                            chartStartDate = Date().addingTimeInterval(-86400 * 7)
                            chartEndDate = Date()
                            endPinned = false
                            showChartTimePicker = false
                        }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("OK") {
                            endPinned = true
                            showChartTimePicker = false
                            rebuildDisplayData()
                        }
                    }
                }
            }
            .presentationDetents([.medium])
        }
        .onChange(of: showExportSheet) { val in
            if !val && shouldExportAfterDismiss {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    exportAndShareDirectly()
                }
            }
        }
        .onReceive(ble.$historyData) { _ in
            rebuildDisplayData()
        }
        .onChange(of: chartStartDate) { _ in
            rebuildDisplayData()
        }
        .onChange(of: chartEndDate) { _ in
            rebuildDisplayData()
        }
        .onChange(of: ble.connectedPeripheralUUID) { _ in
            rebuildDisplayData()
        }
        .onAppear {
            endPinned = false
            rebuildDisplayData()
        }
    }

    private func rebuildDisplayData() {
        guard let currentUUID = ble.connectedPeripheralUUID else {
            displayData = []
            return
        }

        displayData = ble.historyData.filter { item in
            guard item.deviceUUID == currentUUID else { return false }
            guard item.timestamp >= chartStartDate else { return false }
            if endPinned {
                return item.timestamp <= chartEndDate
            } else {
                return true
            }
        }
    }

    private func exportAndShareDirectly() {
        let filtered = ble.historyData.filter { item in
            let timeMatch = item.timestamp >= startDate && item.timestamp <= endDate
            let deviceMatch = selectedDeviceUUID == nil || item.deviceUUID == selectedDeviceUUID
            return timeMatch && deviceMatch
        }

        let header = "No,Device Name,Time,Seq,Lac Value(mmol/L)\n"
        var csv = header
        for (i, item) in filtered.enumerated() {
            csv += "\(i + 1),\(item.deviceName),\(item.timeStr),\(item.seq.map(String.init) ?? ""),\(String(format: "%.2f", item.value))\n"
        }

        let fileName = "Lactate_\(Date().timeIntervalSince1970).csv"
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

        do {
            try csv.write(to: path, atomically: true, encoding: .utf8)

            DispatchQueue.main.async {
                guard let window = UIApplication.shared.connectedScenes
                    .filter({ $0.activationState == .foregroundActive })
                    .compactMap({ $0 as? UIWindowScene })
                    .first?.windows
                    .first else { return }

                let vc = window.rootViewController
                let activity = UIActivityViewController(activityItems: [path], applicationActivities: nil)

                if UIDevice.current.userInterfaceIdiom == .pad {
                    activity.popoverPresentationController?.sourceView = window
                    activity.popoverPresentationController?.sourceRect = CGRect(x: window.bounds.midX, y: window.bounds.midY, width: 0, height: 0)
                }

                vc?.present(activity, animated: true)
                shouldExportAfterDismiss = false
            }
        } catch {
            print("Export Error: \(error)")
            shouldExportAfterDismiss = false
        }
    }
}

// MARK: - Top Buttons

struct TopControlView: View {
    @ObservedObject var ble: BLEManager
    @Binding var showExportSheet: Bool
    @Binding var showDeviceList: Bool

    var body: some View {
        VStack(spacing: 8) {
            Text(ble.status)
                .font(.subheadline)
                .foregroundColor(.blue)

            HStack(spacing: 10) {
                Button("Export CSV") { showExportSheet = true }
                    .frame(width: 160, height: 50)
                    .background(Color.green)
                    .foregroundColor(.white)
                    .cornerRadius(12)

                Button("Scan Devices") {
                    ble.startScan()
                    showDeviceList = true
                }
                .frame(width: 160, height: 50)
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(12)
            }
        }
        .padding(.horizontal)
    }
}

struct DeviceListView: View {
    @ObservedObject var ble: BLEManager
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            List {
                ForEach(ble.foundDevices, id: \.identifier) { device in
                    Button {
                        ble.connect(device)
                        isPresented = false
                    } label: {
                        Text(device.name ?? "Unknown Device")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 12)
                    }
                    .listRowBackground(Color.white)
                }
            }
            .background(Color.white)
            .scrollContentBackground(.hidden)
            .navigationTitle("Available Devices")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { isPresented = false }
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.blue)
                }
            }
        }
    }
}

// MARK: - Chart

struct LactateChartView: View {
    let data: [DataPoint]
    let yRange: ClosedRange<Float>

    var body: some View {
        Chart(data) { item in
            LineMark(
                x: .value("Time", item.timestamp),
                y: .value("Lactate", item.value)
            )
            .interpolationMethod(.catmullRom)
            .foregroundStyle(.red)
            .lineStyle(StrokeStyle(lineWidth: 2))

            PointMark(
                x: .value("Time", item.timestamp),
                y: .value("Lactate", item.value)
            )
            .foregroundStyle(.red)
            .symbol(Circle())
            .symbolSize(30)
        }
        .chartXAxisLabel("Time")
        .chartYAxisLabel("mmol/L")
        .chartYScale(domain: yRange)
        .frame(height: 200)
        .padding(.horizontal)
    }
}

// MARK: - Table

struct LactateTableView: View {
    let data: [DataPoint]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("No.").bold()
                Spacer()
                Text("Device").bold()
                Spacer()
                Text("Time").bold()
                Spacer()
                Text("Seq").bold()
                Spacer()
                Text("Lac Value").bold()
            }
            .padding(.vertical, 6)
            .background(Color.gray.opacity(0.15))

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(data.reversed().enumerated()), id: \.element.id) { idx, item in
                        HStack {
                            Text("\(idx + 1)")
                            Spacer()
                            Text(item.deviceName)
                            Spacer()
                            Text(item.timeStr)
                            Spacer()
                            Text(item.seq.map(String.init) ?? "")
                            Spacer()
                            Text(String(format: "%.2f", item.value))
                        }
                        .padding(.vertical, 8)
                        .foregroundColor(idx % 2 == 0 ? .black : .white)
                        .background(idx % 2 == 0 ? Color.white : Color(red: 0.1, green: 0.8, blue: 0.1))
                    }
                }
            }
            .frame(height: 180)
        }
        .padding(.horizontal)
    }
}

// MARK: - Export Filter

struct ExportFilterView: View {
    @Binding var startDate: Date
    @Binding var endDate: Date
    @Binding var selectedDeviceUUID: String?
    let allDevices: [(uuid: String, name: String)]
    let onExport: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("Device Filter") {
                    Picker("Select Device", selection: $selectedDeviceUUID) {
                        Text("All Devices").tag(String?.none)
                        ForEach(allDevices, id: \.uuid) { dev in
                            Text(dev.name).tag(String?.some(dev.uuid))
                        }
                    }
                }

                Section("Time Range") {
                    DatePicker("Start Time", selection: $startDate, displayedComponents: [.date, .hourAndMinute])
                    DatePicker("End Time", selection: $endDate, displayedComponents: [.date, .hourAndMinute])
                }

                HStack {
                    Button("Cancel", action: onCancel)
                        .foregroundColor(.red)
                    Spacer()
                    Button("Export", action: onExport)
                        .foregroundColor(.green)
                }
            }
            .navigationTitle("Export Options")
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Data Model

enum DeviceSampleInterval {
    case lactate1min
    case glucose3min

    var secondsPerSample: TimeInterval {
        switch self {
        case .lactate1min: return 60
        case .glucose3min: return 180
        }
    }
}

struct DataPoint: Identifiable, Codable {
    let id: UUID
    let value: Float
    var timestamp: Date
    let deviceName: String
    let deviceUUID: String
    let seq: Int?

    init(id: UUID = UUID(), value: Float, timestamp: Date, deviceName: String, deviceUUID: String, seq: Int?) {
        self.id = id
        self.value = value
        self.timestamp = timestamp
        self.deviceName = deviceName
        self.deviceUUID = deviceUUID
        self.seq = seq
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    var timeStr: String { Self.formatter.string(from: timestamp) }
}

// MARK: - BLE Manager

final class BLEManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let shared = BLEManager()

    private let storageKey = "LactateHistoryData"
    private let activationStorageKey = "DeviceActivationTimes"
    private let lastSeqStorageKey = "DeviceLastSeqs"

    private let targetServiceUUID = CBUUID(string: "8653000A-43E6-47B7-9CB0-5FC21D4AE340")
    private let notifyCharUUID = CBUUID(string: "8653000B-43E6-47B7-9CB0-5FC21D4AE340")
    private let writeCharUUID = CBUUID(string: "8653000C-43E6-47B7-9CB0-5FC21D4AE340")

    @Published var status = "Waiting Bluetooth"
    @Published var lactate = "0.00 mmol/L"
    @Published var rawData = "Waiting data..."
    @Published var historyData: [DataPoint] = [] { didSet { saveToLocal() } }
    @Published var foundDevices: [CBPeripheral] = []

    @Published var connectedPeripheralUUID: String? = nil
    @Published var connectedPeripheralName: String? = nil

    @Published var showRawSendPanel: Bool = false
    @Published var rawHexToSend: String = ""

    private var central: CBCentralManager!
    private var notifyPeripheral: CBPeripheral?
    private var notifyCharacteristic: CBCharacteristic?
    private var writeCharacteristic: CBCharacteristic?

    private var activationTimes: [String: Date] = [:] {
        didSet { saveActivationTimes() }
    }

    private var lastSeqs: [String: Int] = [:] {
        didSet { saveLastSeqs() }
    }

    private var didTriggerInitialSyncForCurrentConnection = false

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
        loadFromLocal()
        loadActivationTimes()
        loadLastSeqs()
        rebuildLastSeqsFromHistoryIfNeeded()
        print("[BLE] Manager initialized. history count=\(historyData.count), activationTimes=\(activationTimes.count), lastSeqs=\(lastSeqs.count)")
    }

    func toggleRawSendPanel() {
        showRawSendPanel.toggle()
        print("[BLE] toggleRawSendPanel => \(showRawSendPanel)")
    }

    func sendRawHexFromUI() {
        sendRawHex(rawHexToSend)
    }

    func fillRawHexHistoryStart0() {
        let pkt = buildHistoryRequestPacket(startSeq: 0)
        rawHexToSend = pkt.map { String(format: "%02x", $0) }.joined(separator: " ")
        print("[BLE] fillRawHexHistoryStart0 => \(rawHexToSend)")
    }

    func sendRawHex(_ hex: String) {
        guard let peripheral = notifyPeripheral, let writeCharacteristic else {
            print("[BLE] sendRawHex aborted: missing peripheral or writeCharacteristic")
            status = "Raw send failed: write not ready"
            return
        }

        let cleaned = hex
            .replacingOccurrences(of: "0x", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\t", with: "")

        guard cleaned.count % 2 == 0, !cleaned.isEmpty else {
            print("[BLE] sendRawHex invalid hex length")
            status = "Raw send failed: invalid hex"
            return
        }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(cleaned.count / 2)
        var idx = cleaned.startIndex
        while idx < cleaned.endIndex {
            let next = cleaned.index(idx, offsetBy: 2)
            let byteStr = String(cleaned[idx..<next])
            guard let b = UInt8(byteStr, radix: 16) else {
                print("[BLE] sendRawHex invalid byte: \(byteStr)")
                status = "Raw send failed: invalid byte"
                return
            }
            bytes.append(b)
            idx = next
        }

        print("[BLE] sendRawHex => \(bytes.map { String(format: "%02x", $0) }.joined(separator: " "))")
        peripheral.writeValue(Data(bytes), for: writeCharacteristic, type: .withResponse)
    }

    func getAvailableDevices() -> [(uuid: String, name: String)] {
        let unique = Dictionary(grouping: historyData, by: { $0.deviceUUID })
        return unique.compactMap {
            guard let item = $0.value.first else { return nil }
            return (item.deviceUUID, item.deviceName)
        }
    }

    private func saveToLocal() {
        if let data = try? JSONEncoder().encode(historyData) {
            UserDefaults.standard.set(data, forKey: storageKey)
            print("[BLE] saveToLocal history count=\(historyData.count)")
        }
    }

    private func loadFromLocal() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            print("[BLE] loadFromLocal no existing history")
            return
        }
        if let arr = try? JSONDecoder().decode([DataPoint].self, from: data) {
            historyData = arr
            print("[BLE] loadFromLocal loaded history count=\(arr.count)")
        } else {
            print("[BLE] loadFromLocal decode failed")
        }
    }

    private func saveActivationTimes() {
        let dict = activationTimes.mapValues { $0.timeIntervalSince1970 }
        UserDefaults.standard.set(dict, forKey: activationStorageKey)
        print("[BLE] saveActivationTimes count=\(activationTimes.count)")
    }

    private func loadActivationTimes() {
        guard let dict = UserDefaults.standard.dictionary(forKey: activationStorageKey) as? [String: TimeInterval] else {
            print("[BLE] loadActivationTimes empty")
            return
        }
        activationTimes = dict.mapValues { Date(timeIntervalSince1970: $0) }
        print("[BLE] loadActivationTimes loaded count=\(activationTimes.count)")
    }

    private func saveLastSeqs() {
        UserDefaults.standard.set(lastSeqs, forKey: lastSeqStorageKey)
        print("[BLE] saveLastSeqs count=\(lastSeqs.count) value=\(lastSeqs)")
    }

    private func loadLastSeqs() {
        if let dict = UserDefaults.standard.dictionary(forKey: lastSeqStorageKey) as? [String: Int] {
            lastSeqs = dict
            print("[BLE] loadLastSeqs loaded=\(dict)")
        } else {
            print("[BLE] loadLastSeqs empty")
        }
    }

    private func rebuildLastSeqsFromHistoryIfNeeded() {
        for item in historyData {
            guard let seq = item.seq else { continue }
            lastSeqs[item.deviceUUID] = max(lastSeqs[item.deviceUUID] ?? seq, seq)
        }
        print("[BLE] rebuildLastSeqsFromHistoryIfNeeded => \(lastSeqs)")
    }

    func startScan() {
        foundDevices.removeAll()
        status = "Scanning..."
        print("[BLE] startScan withServices=nil")
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

        print("[BLE] connect peripheral name=\(peripheral.name ?? "nil") uuid=\(peripheral.identifier.uuidString)")
        central.connect(peripheral)
    }

    func manualSyncHistory() {
        print("[BLE] manualSyncHistory called. peripheralReady=\(notifyPeripheral != nil) writeReady=\(writeCharacteristic != nil) notifyReady=\(notifyCharacteristic != nil)")
        guard notifyPeripheral != nil, writeCharacteristic != nil else {
            status = "Sync failed: write channel not ready"
            print("[BLE] manualSyncHistory aborted: write channel not ready")
            return
        }

        status = "Manual history sync..."
        sendSetTime()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.sendHistoryRequest(startSeqOverride: nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.sendHistoryStreamStart()
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        status = central.state == .poweredOn ? "Bluetooth ON → Ready" : "Bluetooth NOT Available"
        print("[BLE] central state updated => \(central.state.rawValue) status=\(status)")
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        print("[BLE] didDiscover name=\(peripheral.name ?? "nil") uuid=\(peripheral.identifier.uuidString) rssi=\(RSSI) adv=\(advertisementData)")
        guard let name = peripheral.name, !name.isEmpty else { return }
        if name.starts(with: "Eaglenos") {
            if !foundDevices.contains(where: { $0.identifier == peripheral.identifier }) {
                foundDevices.append(peripheral)
                print("[BLE] added found device => \(name)")
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        status = "Connected: \(peripheral.name ?? "Device")"
        print("[BLE] didConnect name=\(peripheral.name ?? "nil") uuid=\(peripheral.identifier.uuidString)")
        peripheral.discoverServices([targetServiceUUID])
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        print("[BLE] didDisconnect name=\(peripheral.name ?? "nil") uuid=\(peripheral.identifier.uuidString) error=\(String(describing: error))")
        if connectedPeripheralUUID == peripheral.identifier.uuidString {
            connectedPeripheralUUID = nil
            connectedPeripheralName = nil
            notifyPeripheral = nil
            notifyCharacteristic = nil
            writeCharacteristic = nil
            didTriggerInitialSyncForCurrentConnection = false
        }
        status = error == nil ? "Disconnected" : "Disconnected → Please reconnect"
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            status = "Discover services error: \(error.localizedDescription)"
            print("[BLE] didDiscoverServices error=\(error)")
            return
        }
        guard let services = peripheral.services else {
            print("[BLE] didDiscoverServices no services")
            return
        }
        print("[BLE] didDiscoverServices count=\(services.count)")
        for s in services {
            print("[BLE] service => \(s.uuid.uuidString)")
            if s.uuid == targetServiceUUID {
                peripheral.discoverCharacteristics([notifyCharUUID, writeCharUUID], for: s)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            status = "Discover chars error: \(error.localizedDescription)"
            print("[BLE] didDiscoverCharacteristics error=\(error)")
            return
        }
        guard let chars = service.characteristics else {
            print("[BLE] didDiscoverCharacteristics no chars for service=\(service.uuid.uuidString)")
            return
        }

        print("[BLE] didDiscoverCharacteristics service=\(service.uuid.uuidString) count=\(chars.count)")
        for c in chars {
            print("[BLE] char => uuid=\(c.uuid.uuidString) properties=\(c.properties.rawValue)")
            if c.uuid == notifyCharUUID {
                notifyCharacteristic = c
                peripheral.setNotifyValue(true, for: c)
                print("[BLE] subscribe notify char => \(c.uuid.uuidString)")
            }
            if c.uuid == writeCharUUID {
                writeCharacteristic = c
                print("[BLE] found write char => \(c.uuid.uuidString)")
            }
        }

        triggerInitialHistorySyncIfReady()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            status = "Notify failed: \(error.localizedDescription)"
            print("[BLE] didUpdateNotificationState error for \(characteristic.uuid.uuidString) => \(error)")
            return
        }
        status = characteristic.isNotifying ? "Notify ON" : "Notify OFF"
        print("[BLE] notify state for \(characteristic.uuid.uuidString) => \(characteristic.isNotifying)")
        triggerInitialHistorySyncIfReady()
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            print("[BLE] didWriteValue error for \(characteristic.uuid.uuidString) => \(error)")
        } else {
            print("[BLE] didWriteValue success for \(characteristic.uuid.uuidString)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            print("[BLE] didUpdateValue error: \(error)")
            return
        }

        guard characteristic.uuid == notifyCharacteristic?.uuid else {
            print("[BLE] didUpdateValue ignored non-notify char=\(characteristic.uuid.uuidString)")
            return
        }
        guard let data = characteristic.value else {
            print("[BLE] didUpdateValue empty data")
            return
        }

        let byteArray = [UInt8](data)
        rawData = byteArray.map { String(format: "%02x ", $0) }.joined()

        let hex = byteArray.map { String(format: "%02x", $0) }.joined(separator: " ")
        print("[BLE] notify <= \(hex)")
        print("[BLE] notify checksum valid => \(validateChecksum(byteArray))")

        let fullDeviceName = peripheral.name ?? "Unknown Device"
        let deviceUUID = peripheral.identifier.uuidString

        if isHistoryPacket(byteArray) {
            print("[BLE] packet classified as HISTORY")
            handleHistoryPacket(byteArray, deviceName: fullDeviceName, deviceUUID: deviceUUID)
        } else if isRealtimePacket(byteArray) {
            print("[BLE] packet classified as REALTIME")
            handleRealtimePacket(byteArray, deviceName: fullDeviceName, deviceUUID: deviceUUID)
        } else {
            print("[BLE] packet classified as ACK/STATUS")
            parseAckOrStatusPacket(byteArray)
        }
    }

    // MARK: - Packet classification

    private func isHistoryPacket(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 6 else { return false }
        guard bytes[0] == 0xEB, bytes[1] == 0x90 else { return false }
        let type = Int(bytes[2]) << 8 | Int(bytes[3])
        let len = Int(bytes[4]) << 8 | Int(bytes[5])
        return type == 0x0004 && (len == 0x00D9 || len == 0x0039)
    }

    private func isRealtimePacket(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 6 else { return false }
        guard bytes[0] == 0xEB, bytes[1] == 0x90, bytes[2] == 0x00, bytes[3] == 0x04 else { return false }
        let len = Int(bytes[4]) << 8 | Int(bytes[5])
        return len == 0x0019
    }

    private func parseAckOrStatusPacket(_ bytes: [UInt8]) {
        guard bytes.count >= 6 else { return }
        let packetType = Int(bytes[2]) << 8 | Int(bytes[3])
        let len = Int(bytes[4]) << 8 | Int(bytes[5])

        var expected: Int? = nil
        if bytes.count >= 4 {
            expected = Int(bytes[bytes.count - 4]) * 256 + Int(bytes[bytes.count - 3])
        }

        let payload = Array(bytes.dropFirst(6).dropLast(4))
        let payloadHex = payload.map { String(format: "%02x", $0) }.joined(separator: " ")

        print("[BLE] ACK/STATUS packet: type=0x\(String(format: "%04X", packetType)) len=0x\(String(format: "%04X", len)) payload=\(payloadHex) checksum=\(expected.map { String(format: "0x%04X", $0) } ?? "nil")")

        if payload.count >= 2 {
            let cmd = Int(payload[0])
            let sub = Int(payload[1])
            print("[BLE] ACK/STATUS decode guess: cmd=0x\(String(format: "%02X", cmd)) sub=0x\(String(format: "%02X", sub))")
        }
    }

    // MARK: - Realtime / History handling

    private func handleRealtimePacket(_ bytes: [UInt8], deviceName: String, deviceUUID: String) {
        guard bytes.count >= 11 else {
            print("[BLE] handleRealtimePacket ignored, too short count=\(bytes.count)")
            return
        }

        let rawVal = Int(bytes[7]) * 256 + Int(bytes[8])
        let value = Float(rawVal) / 100.0
        let seq = parseRealtimeSeq(from: bytes)
        print("[BLE] realtime parsed value=\(value) seq=\(String(describing: seq)) device=\(deviceName)")

        DispatchQueue.main.async {
            self.connectedPeripheralUUID = deviceUUID
            self.connectedPeripheralName = deviceName
            self.lactate = String(format: "%.2f mmol/L", value)
            self.status = "Receiving realtime data..."

            if self.activationTimes[deviceUUID] == nil, let seq {
                let interval = self.deviceInterval(for: deviceName)
                let activation = Date().addingTimeInterval(-TimeInterval(seq) * interval.secondsPerSample)
                self.activationTimes[deviceUUID] = activation
                print("[BLE] inferred activation time for \(deviceUUID) => \(activation) from seq=\(seq)")
                self.recomputeTimestamps(for: deviceUUID, deviceName: deviceName)
            }

            let timestamp = self.computeTimestamp(deviceUUID: deviceUUID, deviceName: deviceName, receiveTime: Date(), seq: seq)
            let point = DataPoint(value: value, timestamp: timestamp, deviceName: deviceName, deviceUUID: deviceUUID, seq: seq)
            self.upsert(point)
        }
    }

    private func handleHistoryPacket(_ bytes: [UInt8], deviceName: String, deviceUUID: String) {
        guard bytes.count > 13 else {
            print("[BLE] handleHistoryPacket ignored, too short count=\(bytes.count)")
            return
        }

        let payload = Array(bytes.dropFirst(6).dropLast(4))
        guard payload.count > 3 else {
            print("[BLE] handleHistoryPacket empty payload after trimming")
            return
        }

        let pageHeader = Array(payload.prefix(3))
        let body = Array(payload.dropFirst(3))
        let recordSize = 16
        let recordCount = body.count / recordSize

        print("[BLE] history page header=\(pageHeader.map { String(format: "%02x", $0) }.joined(separator: " ")) payloadLength=\(payload.count) bodyLength=\(body.count) recordSize=\(recordSize) recordCount=\(recordCount)")
        guard recordCount > 0 else { return }

        var points: [DataPoint] = []
        for i in 0..<recordCount {
            let start = i * recordSize
            let rec = Array(body[start..<(start + recordSize)])
            let recHex = rec.map { String(format: "%02x", $0) }.joined(separator: " ")

            let seq = Int(rec[0]) * 256 + Int(rec[1])
            let candidate1 = Int(rec[2]) * 256 + Int(rec[3])
            let candidate2 = Int(rec[4]) * 256 + Int(rec[5])
            let candidate3 = Int(rec[10]) * 256 + Int(rec[11])
            let candidate4 = Int(rec[14]) * 256 + Int(rec[15])
            let value = Float(candidate4) / 100.0
            let timestamp = computeTimestamp(deviceUUID: deviceUUID, deviceName: deviceName, receiveTime: Date(), seq: seq)

            print("[BLE] history rec[\(i)] raw=\(recHex) seq=\(seq) c1=\(candidate1) c2=\(candidate2) c3=\(candidate3) c4=\(candidate4) chosen=\(candidate4) value=\(value) timestamp=\(timestamp)")
            points.append(DataPoint(value: value, timestamp: timestamp, deviceName: deviceName, deviceUUID: deviceUUID, seq: seq))
        }

        DispatchQueue.main.async {
            self.connectedPeripheralUUID = deviceUUID
            self.connectedPeripheralName = deviceName
            self.status = "Receiving history data..."

            for p in points {
                self.upsert(p)
            }
        }
    }

    private func upsert(_ point: DataPoint) {
        if let seq = point.seq,
           let idx = historyData.firstIndex(where: { $0.deviceUUID == point.deviceUUID && $0.seq == seq }) {
            print("[BLE] upsert replace existing seq=\(seq) for device=\(point.deviceUUID)")
            historyData[idx] = point
        } else {
            print("[BLE] upsert append seq=\(String(describing: point.seq)) value=\(point.value) time=\(point.timestamp)")
            historyData.append(point)
        }

        if let seq = point.seq {
            let old = lastSeqs[point.deviceUUID]
            lastSeqs[point.deviceUUID] = max(lastSeqs[point.deviceUUID] ?? seq, seq)
            print("[BLE] lastSeq update device=\(point.deviceUUID) old=\(String(describing: old)) new=\(String(describing: lastSeqs[point.deviceUUID]))")
        }
    }

    // MARK: - History sync

    private func triggerInitialHistorySyncIfReady() {
        print("[BLE] triggerInitialHistorySyncIfReady called triggered=\(didTriggerInitialSyncForCurrentConnection) peripheralReady=\(notifyPeripheral != nil) notifyReady=\(notifyCharacteristic != nil) writeReady=\(writeCharacteristic != nil) notifyOn=\(notifyCharacteristic?.isNotifying ?? false)")
        guard !didTriggerInitialSyncForCurrentConnection else { return }
        guard let peripheral = notifyPeripheral,
              let notifyCharacteristic,
              let writeCharacteristic,
              notifyCharacteristic.isNotifying,
              peripheral.state == .connected else {
            return
        }

        didTriggerInitialSyncForCurrentConnection = true
        status = "Syncing device time and history..."
        print("[BLE] auto history sync starting using writeChar=\(writeCharacteristic.uuid.uuidString)")

        sendSetTime()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.sendHistoryRequest(startSeqOverride: nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.sendHistoryStreamStart()
        }
    }

    private func sendSetTime() {
        guard let peripheral = notifyPeripheral, let writeCharacteristic else {
            print("[BLE] sendSetTime aborted: missing peripheral or writeCharacteristic")
            return
        }
        let packet = buildSetTimePacket(date: Date())
        print("[BLE] sendSetTime => \(packet.map { String(format: "%02x", $0) }.joined(separator: " "))")
        let data = Data(packet)
        peripheral.writeValue(data, for: writeCharacteristic, type: .withResponse)
    }

    private func sendHistoryRequest(startSeqOverride: Int?) {
        guard let peripheral = notifyPeripheral,
              let writeCharacteristic,
              let deviceUUID = connectedPeripheralUUID else {
            print("[BLE] sendHistoryRequest aborted: missing peripheral/writeCharacteristic/deviceUUID")
            return
        }

        let startSeq: Int
        if let startSeqOverride {
            startSeq = startSeqOverride & 0xFFFF
        } else if let last = lastSeqs[deviceUUID] {
            startSeq = (last + 1) & 0xFFFF
        } else {
            startSeq = 0
        }

        let packet = buildHistoryRequestPacket(startSeq: startSeq)
        print("[BLE] sendHistoryRequest startSeq=\(startSeq) => \(packet.map { String(format: "%02x", $0) }.joined(separator: " "))")
        let data = Data(packet)
        peripheral.writeValue(data, for: writeCharacteristic, type: .withResponse)
    }

    private func sendHistoryStreamStart() {
        guard let peripheral = notifyPeripheral, let writeCharacteristic else {
            print("[BLE] sendHistoryStreamStart aborted: missing peripheral or writeCharacteristic")
            return
        }

        let packet = buildHistoryStreamStartPacket()
        print("[BLE] sendHistoryStreamStart => \(packet.map { String(format: "%02x", $0) }.joined(separator: " "))")
        peripheral.writeValue(Data(packet), for: writeCharacteristic, type: .withResponse)
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
            0xEB, 0x90, 0x00, 0x03, 0x00, 0x13,
            0x01, 0x00, 0x00, 0x00,
            UInt8((year >> 8) & 0xFF), UInt8(year & 0xFF),
            UInt8(month & 0xFF), UInt8(day & 0xFF),
            UInt8(hour & 0xFF), UInt8(minute & 0xFF), UInt8(second & 0xFF),
            0x00
        ]

        let sum = checksum16(payload)
        payload.append(UInt8((sum >> 8) & 0xFF))
        payload.append(UInt8(sum & 0xFF))
        payload.append(0x0D)
        payload.append(0x0A)
        return payload
    }

    private func buildHistoryRequestPacket(startSeq: Int) -> [UInt8] {
        var payload: [UInt8] = [
            0xEB, 0x90, 0x00, 0x04, 0x00, 0x0D,
            0x07, 0x00, 0x00,
            UInt8((startSeq >> 8) & 0xFF), UInt8(startSeq & 0xFF)
        ]

        let sum = checksum16(payload)
        payload.append(UInt8((sum >> 8) & 0xFF))
        payload.append(UInt8(sum & 0xFF))
        payload.append(0x0D)
        payload.append(0x0A)
        return payload
    }

    private func buildHistoryStreamStartPacket() -> [UInt8] {
        var payload: [UInt8] = [
            0xEB, 0x90, 0x00, 0x06, 0x00, 0x0D,
            0x07, 0x00, 0x00, 0x00, 0x01
        ]
        let sum = checksum16(payload)
        payload.append(UInt8((sum >> 8) & 0xFF))
        payload.append(UInt8(sum & 0xFF))
        payload.append(0x0D)
        payload.append(0x0A)
        return payload
    }

    private func checksum16(_ bytes: [UInt8]) -> UInt16 {
        bytes.reduce(0) { ($0 + UInt16($1)) & 0xFFFF }
    }

    private func validateChecksum(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 4 else { return false }
        let payload = Array(bytes.dropLast(4))
        let expected = Int(bytes[bytes.count - 4]) * 256 + Int(bytes[bytes.count - 3])
        let actual = Int(checksum16(payload))
        return expected == actual
    }

    // MARK: - Timestamp helpers

    private func deviceInterval(for deviceName: String) -> DeviceSampleInterval {
        let upper = deviceName.uppercased()
        if upper.contains("CLM") {
            return .lactate1min
        }
        if upper.contains("CGM") {
            return .glucose3min
        }
        let lower = deviceName.lowercased()
        if lower.contains("lac") || lower.contains("lact") {
            return .lactate1min
        }
        return .glucose3min
    }

    private func computeTimestamp(deviceUUID: String, deviceName: String, receiveTime: Date, seq: Int?) -> Date {
        guard let seq, let activation = activationTimes[deviceUUID] else {
            return receiveTime
        }
        let interval = deviceInterval(for: deviceName)
        return activation.addingTimeInterval(TimeInterval(seq) * interval.secondsPerSample)
    }

    private func recomputeTimestamps(for deviceUUID: String, deviceName: String) {
        guard let activation = activationTimes[deviceUUID] else { return }
        let interval = deviceInterval(for: deviceName)

        for idx in historyData.indices {
            guard historyData[idx].deviceUUID == deviceUUID else { continue }
            guard let seq = historyData[idx].seq else { continue }
            historyData[idx].timestamp = activation.addingTimeInterval(TimeInterval(seq) * interval.secondsPerSample)
        }
        print("[BLE] recomputeTimestamps completed for device=\(deviceUUID)")
    }

    private func parseRealtimeSeq(from bytes: [UInt8]) -> Int? {
        guard isRealtimePacket(bytes) else { return nil }
        guard bytes.count >= 11 else { return nil }
        return Int(bytes[9]) * 256 + Int(bytes[10])
    }
}

#Preview {
    ContentView()
}
