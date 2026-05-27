// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-License-Identifier: GPL-3.0-or-later

//
//  Nextcloud iOS + Expo Brownfield demo
//
//  Bootstraps the embedded React Native runtime, seeds shared state with
//  a mock recent-files snapshot, listens for messages from the Files
//  Quick Look RN screen, and observes the brownfield `popToNative`
//  notification so the JS-side dismiss API works when the RN screen is
//  presented modally.
//

#if os(iOS)
    public import Foundation
    public import UIKit
    internal import NextcloudExpo

    @objc public final class ExpoIntegration: NSObject {
        /// Call from AppDelegate.didFinishLaunchingWithOptions.
        @objc public static func bootstrap() {
            ReactNativeHostManager.shared.initialize()
            seedSharedState()
            registerMessageHandlers()
            observePopToNative()
        }

        @objc public static func makeFilesQuickLookViewController() -> UIViewController {
            let rn = ReactNativeViewController(moduleName: "main")
            rn.modalPresentationStyle = .fullScreen
            return rn
        }

        @objc public static func scheduleAutoPresentIfRequested() {
            guard UserDefaults.standard.bool(forKey: "NextcloudExpoAutoPresent") else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                presentOnKeyWindow()
                if UserDefaults.standard.bool(forKey: "NextcloudExpoAutoDemo") {
                    scheduleDemoActions()
                }
            }
        }

        private static func scheduleDemoActions() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { syncNow() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.5) {
                BrownfieldMessaging.sendMessage([
                    "type": "FILE_OPENED",
                    "name": "brownfield-notes.md",
                ])
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 9.0) {
                NotificationCenter.default.post(
                    name: Notification.Name("popToNative"),
                    object: nil,
                    userInfo: ["animated": true]
                )
            }
        }

        private static func observePopToNative() {
            NotificationCenter.default.addObserver(
                forName: Notification.Name("popToNative"),
                object: nil,
                queue: .main
            ) { note in
                let animated = (note.userInfo?["animated"] as? Bool) ?? false
                dismissPresentation(animated: animated)
            }
        }

        private static func dismissPresentation(animated: Bool) {
            guard let scene = UIApplication.shared.connectedScenes
                    .compactMap({ $0 as? UIWindowScene }).first,
                  let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first,
                  let root = window.rootViewController
            else { return }
            var presenter = root
            while let next = presenter.presentedViewController { presenter = next }
            presenter.dismiss(animated: animated)
        }

        private static func presentOnKeyWindow() {
            guard let scene = UIApplication.shared.connectedScenes
                    .compactMap({ $0 as? UIWindowScene }).first,
                  let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first,
                  let root = window.rootViewController
            else { return }
            var presenter = root
            while let next = presenter.presentedViewController { presenter = next }
            if presenter !== root {
                presenter.dismiss(animated: false) {
                    root.present(makeFilesQuickLookViewController(), animated: true)
                }
            } else {
                root.present(makeFilesQuickLookViewController(), animated: true)
            }
        }

        private static func seedSharedState() {
            let now = ISO8601DateFormatter().string(from: Date())
            BrownfieldState.set("totalFiles", 1284)
            BrownfieldState.set("usedGB", 12.3 as Double)
            BrownfieldState.set("quotaGB", 50 as Int)
            BrownfieldState.set("pendingUploads", 3)
            BrownfieldState.set("lastSyncedAt", now)
            BrownfieldState.set("recentFiles", sampleFiles())
        }

        private static func sampleFiles() -> [[String: Any]] {
            [
                [
                    "id": 1,
                    "name": "brownfield-notes.md",
                    "path": "/Documents/Engineering",
                    "ext": "md",
                    "color": "#0082C9",
                    "size": "12 KB",
                    "modified": "2 min ago",
                    "shared": false,
                ],
                [
                    "id": 2,
                    "name": "Q2 roadmap.xlsx",
                    "path": "/Shared/Product",
                    "ext": "xls",
                    "color": "#107C41",
                    "size": "1.2 MB",
                    "modified": "1 h ago",
                    "shared": true,
                ],
                [
                    "id": 3,
                    "name": "rn-screen.mov",
                    "path": "/Captures",
                    "ext": "mov",
                    "color": "#9B51E0",
                    "size": "8.7 MB",
                    "modified": "Yesterday",
                    "shared": false,
                ],
                [
                    "id": 4,
                    "name": "expo-brownfield.pdf",
                    "path": "/Documents/Specs",
                    "ext": "pdf",
                    "color": "#EB5757",
                    "size": "468 KB",
                    "modified": "Mon",
                    "shared": true,
                ],
                [
                    "id": 5,
                    "name": "Family Holiday.zip",
                    "path": "/Personal",
                    "ext": "zip",
                    "color": "#F2994A",
                    "size": "243 MB",
                    "modified": "Last week",
                    "shared": false,
                ],
            ]
        }

        private static func registerMessageHandlers() {
            _ = BrownfieldMessaging.addListener { message in
                guard let type = message["type"] as? String else { return }
                switch type {
                case "OPEN_FILE":
                    openFile(message)
                case "SYNC_NOW":
                    syncNow()
                default:
                    break
                }
            }
        }

        private static func openFile(_ message: [String: Any?]) {
            BrownfieldMessaging.sendMessage([
                "type": "FILE_OPENED",
                "id": (message["id"] ?? 0) as Any,
                "name": (message["name"] ?? "") as Any,
            ])
        }

        private static func syncNow() {
            let pending = (BrownfieldState.get("pendingUploads") as? Int) ?? 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                BrownfieldState.set("pendingUploads", 0)
                BrownfieldState.set("totalFiles", ((BrownfieldState.get("totalFiles") as? Int) ?? 0) + pending)
                BrownfieldState.set("lastSyncedAt", ISO8601DateFormatter().string(from: Date()))
                BrownfieldMessaging.sendMessage([
                    "type": "SYNC_FINISHED",
                    "uploaded": pending,
                ])
            }
        }
    }
#endif
