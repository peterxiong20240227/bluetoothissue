//
//  ClmReaderSubviews.swift
//  LactateExpress
//
//  Created by eagle on 2026/4/14.
//

import Charts
import CoreBluetooth
import SwiftUI

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

struct LactateTableView: View {
    let data: [DataPoint]

    func isRound(_ idx: Int) -> Bool {
        idx.isMultiple(of: 2)
    }

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
                        let isRound = idx.isMultiple(of: 2)
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
                        .foregroundColor(isRound ? .black : .white)
                        .background(isRound ? Color.white : Color(red: 0.1, green: 0.8, blue: 0.1))
                    }
                }
            }
            .frame(height: 180)
        }
        .padding(.horizontal)
    }
}

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
