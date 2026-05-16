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

        let header = "No,Device Name,Time,Lac Value(mmol/L)\n"
        var csv = header
        for (i, item) in filtered.enumerated() {
            csv += "\(i + 1),\(item.deviceName),\(item.timeStr),\(String(format: "%.2f", item.value))\n"
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
            HStack{
                Text("No.").bold()
                Spacer()
                Text("Device").bold()
                Spacer()
                Text("Time").bold()
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

struct DataPoint: Identifiable, Codable {
    let id: UUID
    let value: Float
    let timestamp: Date
    let deviceName: String
    let deviceUUID: String

    init(id: UUID = UUID(), value: Float, timestamp: Date, deviceName: String, deviceUUID: String) {
        self.id = id
        self.value = value
        self.timestamp = timestamp
        self.deviceName = deviceName
        self.deviceUUID = deviceUUID
    }

    private static let _formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    var timeStr: String { Self._formatter.string(from: timestamp) }
}

// MARK: - BLE Manager

final class BLEManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let shared = BLEManager()
    private let storageKey = "LactateHistoryData"

    @Published var status = "Waiting Bluetooth"
    @Published var lactate = "0.00 mmol/L"
    @Published var rawData = "Waiting data..."
    @Published var historyData: [DataPoint] = [] { didSet { saveToLocal() } }
    @Published var foundDevices: [CBPeripheral] = []

    @Published var connectedPeripheralUUID: String? = nil
    @Published var connectedPeripheralName: String? = nil

    private var central: CBCentralManager!
    private var notifyPeripheral: CBPeripheral?
    private var notifyCharacteristic: CBCharacteristic?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
        loadFromLocal()
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
        }
    }

    private func loadFromLocal() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return }
        if let arr = try? JSONDecoder().decode([DataPoint].self, from: data) {
            historyData = arr
        }
    }

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
        central.connect(peripheral)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        status = central.state == .poweredOn ? "Bluetooth ON → Ready" : "Bluetooth NOT Available"
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        guard let name = peripheral.name, !name.isEmpty else { return }
        if name.starts(with: "Eaglenos") {
            if !foundDevices.contains(where: { $0.identifier == peripheral.identifier }) {
                foundDevices.append(peripheral)
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        status = "Connected: \(peripheral.name ?? "Device")"
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if connectedPeripheralUUID == peripheral.identifier.uuidString {
            connectedPeripheralUUID = nil
            connectedPeripheralName = nil
            notifyPeripheral = nil
            notifyCharacteristic = nil
        }
        status = error == nil ? "Disconnected" : "Disconnected → Please reconnect"
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            status = "Discover services error: \(error.localizedDescription)"
            return
        }
        guard let services = peripheral.services else { return }
        for s in services {
            peripheral.discoverCharacteristics(nil, for: s)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            status = "Discover chars error: \(error.localizedDescription)"
            return
        }
        guard let chars = service.characteristics else { return }

        if notifyCharacteristic == nil {
            if let c = chars.first(where: { $0.properties.contains(.notify) }) {
                notifyCharacteristic = c
                peripheral.setNotifyValue(true, for: c)
                status = "Subscribing notify..."
                print("Subscribe notify char: \(c.uuid.uuidString) on service: \(service.uuid.uuidString)")
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            status = "Notify failed: \(error.localizedDescription)"
            print("Notify failed for \(characteristic.uuid.uuidString): \(error)")
            return
        }
        status = characteristic.isNotifying ? "Notify ON" : "Notify OFF"
        print("Notify state for \(characteristic.uuid.uuidString) = \(characteristic.isNotifying)")
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            print("didUpdateValue error: \(error)")
            return
        }

        guard characteristic.uuid == notifyCharacteristic?.uuid else { return }
        guard let data = characteristic.value else { return }

        var byteArray = [UInt8](repeating: 0, count: data.count)
        data.copyBytes(to: &byteArray, count: byteArray.count)
        rawData = byteArray.map { String(format: "%02x ", $0) }.joined()

        guard byteArray.count >= 9 else { return }
        let high = Int(byteArray[7])
        let low = Int(byteArray[8])
        let rawVal = high * 256 + low
        let value = Float(rawVal) / 100.0

        let fullDeviceName = peripheral.name ?? "Unknown Device"
        let deviceUUID = peripheral.identifier.uuidString

        DispatchQueue.main.async {
            self.connectedPeripheralUUID = deviceUUID
            self.connectedPeripheralName = fullDeviceName

            self.lactate = String(format: "%.2f mmol/L", value)
            self.status = "Receiving data..."

            let point = DataPoint(
                value: value,
                timestamp: Date(),
                deviceName: fullDeviceName,
                deviceUUID: deviceUUID
            )
            self.historyData.append(point)
        }
    }
}

#Preview {
    ContentView()
}
