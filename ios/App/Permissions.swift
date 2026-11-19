import Foundation
import UIKit
import UserNotifications
import EventKit
import MusicKit
import AVFoundation
import Photos
import WebKit

/// Berechtigungen an einer Stelle: Stand abfragen, erlauben lassen, sonst in die iOS-Einstellungen springen.
/// Das Portal fragt über postMessage({type:'perm', op:'status'|'request'|'settings', name, req}) an.
@MainActor
enum Permissions {
    static let names = ["notifications", "reminders", "music", "camera", "microphone", "photos"]

    /// "granted" | "notDetermined" | "denied" | "limited"
    static func status(_ name: String) async -> String {
        switch name {
        case "notifications":
            switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
            case .authorized, .provisional, .ephemeral: return "granted"
            case .notDetermined: return "notDetermined"
            default: return "denied"
            }
        case "reminders":
            let s = EKEventStore.authorizationStatus(for: .reminder)
            if #available(iOS 17.0, *), s == .fullAccess { return "granted" }
            if s == .notDetermined { return "notDetermined" }
            if #available(iOS 17.0, *), s == .writeOnly { return "limited" }
            return s.rawValue == 3 ? "granted" : "denied"     // 3 = .authorized (ältere Systeme)
        case "music":
            switch MusicAuthorization.currentStatus {
            case .authorized: return "granted"
            case .notDetermined: return "notDetermined"
            default: return "denied"
            }
        case "camera", "microphone":
            switch AVCaptureDevice.authorizationStatus(for: name == "camera" ? .video : .audio) {
            case .authorized: return "granted"
            case .notDetermined: return "notDetermined"
            default: return "denied"
            }
        case "photos":
            switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
            case .authorized: return "granted"
            case .limited: return "limited"
            case .notDetermined: return "notDetermined"
            default: return "denied"
            }
        default: return "denied"
        }
    }

    static func all() async -> [String: String] {
        var out: [String: String] = [:]
        for n in names { out[n] = await status(n) }
        return out
    }

    /// Fragt nur, wenn iOS noch nicht gefragt hat; sonst öffnet es die Einstellungen der App (dort lässt es sich ändern).
    static func request(_ name: String) async -> String {
        let before = await status(name)
        if before == "granted" { return before }
        if before != "notDetermined" { openSettings(); return before }
        switch name {
        case "notifications":
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        case "reminders":
            _ = await ReminderSync.requestAccess()
        case "music":
            _ = await MusicAuthorization.request()
        case "camera", "microphone":
            _ = await AVCaptureDevice.requestAccess(for: name == "camera" ? .video : .audio)
        case "photos":
            _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        default: break
        }
        return await status(name)
    }

    static func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }

    static func handle(_ msg: [String: Any], web: WKWebView?) {
        let req = msg["req"] as? Int ?? 0
        let name = msg["name"] as? String ?? ""
        Task { @MainActor in
            var data: [String: Any] = [:]
            switch msg["op"] as? String {
            case "request": data = ["name": name, "status": await request(name)]
            case "settings": openSettings(); data = ["ok": true]
            default: data = await all()
            }
            guard req > 0, let json = try? JSONSerialization.data(withJSONObject: data) else { return }
            web?.evaluateJavaScript("window.portalNative && portalNative.reply(\(req), \(String(decoding: json, as: UTF8.self)))", completionHandler: nil)
        }
    }
}
