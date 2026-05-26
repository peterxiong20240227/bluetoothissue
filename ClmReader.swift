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
    @State private var chartStartDate = Date().addingTimeInterval(-43200)
    @State private var chartEndDate = Date()
    @State private var showChartTimePicker = false
    @State private var showManualSyncSheet = false
    @State private var manualSyncSeqInput = ""
    @State private var showClearHistoryAlert = false
    @State private var showActivationTimeSheet = false
    @State private var manualActivationTime = Date()
    @State private var endPinned = false
    @State private var displayData: [DataPoint] = []

    private var chartYRange: ClosedRange<Float> {
        let values = displayData.map { $0.value }
        guard !values.isEmpty else { return 0 ... 10 }
        let maxVal = values.max() ?? 10
        return 0 ... (maxVal + 1)
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
                        if let currentUUID = ble.connectedPeripheralUUID {
                            let suggested = ble.nextMissingSeq(for: currentUUID)
                            manualSyncSeqInput = suggested.map(String.init) ?? ""
                        } else {
                            manualSyncSeqInput = ""
                        }
                        showManualSyncSheet = true
                    } label: {
                        Text("Sync History")
                            .font(.subheadline)
                            .foregroundColor(.white)
                            .padding(6)
                            .background(Color.purple)
                            .cornerRadius(8)
                    }

                    Button {
                        manualActivationTime = ble.activationTimeForConnectedDevice() ?? Date()
                        showActivationTimeSheet = true
                    } label: {
                        Text("Set Activation Time")
                            .font(.subheadline)
                            .foregroundColor(.white)
                            .padding(6)
                            .background(Color.teal)
                            .cornerRadius(8)
                    }

//                    Button {
//                        showClearHistoryAlert = true
//                    } label: {
//                        Text("Clear History")
//                            .font(.subheadline)
//                            .foregroundColor(.white)
//                            .padding(6)
//                            .background(Color.red)
//                            .cornerRadius(8)
//                    }
                }

                HStack(spacing: 10) {
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
                }

                Button {
                    endPinned = false
                    chartStartDate = Date().addingTimeInterval(-43200)
                    chartEndDate = Date()
                    rebuildDisplayData()
                } label: {
                    Text("Live Mode (Last 12 Hours)")
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
                        Button("Reset 12h") {
                            chartStartDate = Date().addingTimeInterval(-43200)
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
        .sheet(isPresented: $showManualSyncSheet) {
            NavigationStack {
                Form {
                    Section("Start Seq") {
                        TextField("Enter seq", text: $manualSyncSeqInput)
                            .keyboardType(.numberPad)
                    }

                    if let currentUUID = ble.connectedPeripheralUUID,
                       let suggested = ble.nextMissingSeq(for: currentUUID) {
                        Section("Suggested") {
                            Text("Suggested missing seq: \(suggested)")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .navigationTitle("Manual History Sync")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            showManualSyncSheet = false
                        }
                    }

                    ToolbarItem(placement: .confirmationAction) {
                        Button("Sync") {
                            if let seq = Int(manualSyncSeqInput) {
                                ble.manualSyncHistory(startSeq: seq)
                            } else {
                                ble.manualSyncHistory(startSeq: nil)
                            }
                            showManualSyncSheet = false
                        }
                    }
                }
            }
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $showActivationTimeSheet) {
            NavigationStack {
                Form {
                    Section("Activation Time") {
                        DatePicker(
                            "Activation Time",
                            selection: $manualActivationTime,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                    }
                }
                .navigationTitle("Set Activation Time")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            showActivationTimeSheet = false
                        }
                    }

                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            ble.setActivationTimeForConnectedDevice(manualActivationTime)
                            rebuildDisplayData()
                            showActivationTimeSheet = false
                        }
                    }
                }
            }
            .presentationDetents([.medium])
        }
        .alert("Clear This Device History?", isPresented: $showClearHistoryAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                ble.clearHistoryForConnectedDevice()
                rebuildDisplayData()
            }
        } message: {
            Text("This will remove all stored history samples for the currently connected device.")
        }
        .onChange(of: showExportSheet) { _, val in
            if !val && shouldExportAfterDismiss {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    exportAndShareDirectly()
                }
            }
        }
        .onReceive(ble.$historyData) { _ in
            rebuildDisplayData()
        }
        .onChange(of: chartStartDate) { _, _ in
            rebuildDisplayData()
        }
        .onChange(of: chartEndDate) { _, _ in
            rebuildDisplayData()
        }
        .onChange(of: ble.connectedPeripheralUUID) { _, _ in
            chartStartDate = Date().addingTimeInterval(-43200)
            chartEndDate = Date()
            endPinned = false
            rebuildDisplayData()
        }
        .onAppear {
            chartStartDate = Date().addingTimeInterval(-43200)
            chartEndDate = Date()
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
                return item.timestamp <= Date()
            }
        }
        .sorted { $0.timestamp < $1.timestamp }
    }

    private func exportAndShareDirectly() {
        let filtered = ble.historyData.filter { item in
            let timeMatch = item.timestamp >= startDate && item.timestamp <= endDate
            let deviceMatch = selectedDeviceUUID == nil || item.deviceUUID == selectedDeviceUUID
            return timeMatch && deviceMatch
        }

        let header = "No,Device Name,Time,Seq,Lac Value(mmol/L)\n"
        var csv = header
        for (idx, item) in filtered.enumerated() {
            csv += "\(idx + 1),\(item.deviceName),\(item.timeStr),\(item.seq.map(String.init) ?? ""),\(String(format: "%.2f", item.value))\n"
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
            shouldExportAfterDismiss = false
        }
    }
}

#Preview {
    ClmReader()
}
