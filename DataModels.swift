//
//  DataModels.swift
//  LactateExpress
//
//  Created by eagle on 2026/4/14.
//

import Foundation

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
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    var timeStr: String { Self.formatter.string(from: timestamp) }
}
