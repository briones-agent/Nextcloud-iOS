// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2024 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import UIKit
import NextcloudKit
import Alamofire
import LucidBanner

extension NCCollectionViewCommon: UICollectionViewDelegate {
    @MainActor
    func didSelectMetadata(_ metadata: tableMetadata, withOcIds: Bool, viewerTransitionSource: NCViewerTransitionSource?) async {
        let capabilities = await NKCapabilities.shared.getCapabilities(for: session.account)

        if metadata.e2eEncrypted {
            if capabilities.e2EEEnabled {
                if !NCPreferences().isEndToEndEnabled(account: metadata.account) {
                    do {
                        let e2ee = NCEndToEndSetup(controller: controller)
                        try await e2ee.start()
                    } catch let error as NKError {
                        if error.errorCode == NSUserCancelledError {
                            return
                        }
                        await showErrorBanner(
                            windowScene: windowScene,
                            text: error.errorDescription
                        )
                        return
                    } catch {
                        // fallback (non NKError)
                        await showErrorBanner(
                            windowScene: windowScene,
                            text: error.localizedDescription
                        )
                        return
                    }
                }
            } else {
                await showInfoBanner(windowScene: windowScene, text: "_e2e_server_disabled_")
                return
            }
        }

        func downloadFile() async {
            var downloadRequest: DownloadRequest?
            var banner: LucidBanner?
            var token: Int?

            (banner, token) = showHudBanner(windowScene: windowScene,
                                            title: "_download_in_progress_",
                                            stage: .button,
                                            onButtonTap: {
                if let request = downloadRequest {
                    request.cancel()
                }
            })

            guard let  metadata = await database.setMetadataSessionInWaitDownloadAsync(ocId: metadata.ocId,
                                                                                       session: self.networking.sessionDownload,
                                                                                       selector: global.selectorLoadFileView,
                                                                                       sceneIdentifier: self.controller?.sceneIdentifier) else {
                return
            }

            let results = await self.networking.downloadFile(metadata: metadata) { request in
                downloadRequest = request
            } progressHandler: { progress in
                Task {@MainActor in
                    banner?.update(
                        payload: LucidBannerPayload.Update(progress: Double(progress.fractionCompleted)),
                        for: token)
                }
            }

            if let banner {
                await banner.dismissAsync()
            }

            if results.nkError == .success || results.afError?.isExplicitlyCancelledError ?? false {
                print("ok")
            } else {
                await showErrorBanner(windowScene: windowScene, text: results.nkError.errorDescription, errorCode: results.nkError.errorCode)
            }
        }

        if metadata.directory {
            await pushMetadata(metadata)
        } else {
            let image = utility.getImage(ocId: metadata.ocId, etag: metadata.etag, ext: self.global.previewExt1024, userId: metadata.userId, urlBase: metadata.urlBase)
            let fileExists = utilityFileSystem.fileProviderStorageExists(metadata)

            // --- E2EE -------
            if metadata.isDirectoryE2EE {
                if fileExists {
                    if let vc = await NCViewer().getViewerController(metadata: metadata, delegate: self, viewerTransitionSource: viewerTransitionSource) {
                        self.navigationController?.pushViewController(vc, animated: true)
                    }
                } else {
                    await downloadFile()
                }
                return
            }
            // ---------------

            if metadata.isImage || metadata.isAudioOrVideo {
                let metadatas = self.dataSource.getMetadatas()
                let ocIds = metadatas.filter { $0.classFile == NKTypeClassFile.image.rawValue ||
                    $0.classFile == NKTypeClassFile.video.rawValue ||
                    $0.classFile == NKTypeClassFile.audio.rawValue }.map(\.ocId)

                if let vc = await NCViewer().getViewerController(metadata: metadata, ocIds: withOcIds ? ocIds : nil, image: image, delegate: self, viewerTransitionSource: viewerTransitionSource) {
                    self.navigationController?.pushViewController(vc, animated: true)
                }
            } else if !metadata.isDirectoryE2EE, metadata.isAvailableEditorView || utilityFileSystem.fileProviderStorageExists(metadata) || metadata.name == self.global.talkName {
                if let vc = await NCViewer().getViewerController(metadata: metadata, image: image, delegate: self, viewerTransitionSource: viewerTransitionSource) {
                    self.navigationController?.pushViewController(vc, animated: true)
                }
            } else if NextcloudKit.shared.isNetworkReachable() {
                guard let  metadata = await database.setMetadataSessionInWaitDownloadAsync(ocId: metadata.ocId,
                                                                                           session: self.networking.sessionDownload,
                                                                                           selector: global.selectorLoadFileView,
                                                                                           sceneIdentifier: self.controller?.sceneIdentifier) else {
                    return
                }

                if metadata.name == "files" {
                    await downloadFile()
                } else if !metadata.url.isEmpty,
                          let vc = await NCViewer().getViewerController(metadata: metadata, delegate: self, viewerTransitionSource: viewerTransitionSource) {
                    self.navigationController?.pushViewController(vc, animated: true)
                }
            } else {
                await showErrorBanner(windowScene: windowScene, text: "_go_online_", errorCode: NCGlobal.shared.errorOfflineNotAllowed)
            }
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let metadata = self.dataSource.getMetadata(indexPath: indexPath) else {
            return
        }
        var viewerTransitionSource: NCViewerTransitionSource?

        if self.isEditMode {
            if let index = self.fileSelect.firstIndex(of: metadata.ocId) {
                self.fileSelect.remove(at: index)
            } else {
                self.fileSelect.append(metadata.ocId)
            }
            self.collectionView.reloadItems(at: [indexPath])
            self.tabBarSelect?.update(fileSelect: self.fileSelect, metadatas: self.getSelectedMetadatas(), userId: metadata.userId)
            self.collectionView.collectionViewLayout.invalidateLayout()
            return
        }

        if let cell = collectionView.cellForItem(at: indexPath) as? NCCellMainProtocol {
            viewerTransitionSource = cell.viewerTransitionSource()
        }

        Task {
            await didSelectMetadata(metadata, withOcIds: true, viewerTransitionSource: viewerTransitionSource)
        }
    }

    /// Returns the transition source for a media item in the collection view.
    ///
    /// If the target cell is visible, the transition uses the real preview image view frame.
    /// If the target cell is not materialized yet, the transition falls back to the
    /// collection view layout attributes so the closing animation can still target
    /// the correct item position.
    ///
    /// - Parameter ocId: Nextcloud file identifier of the media item.
    /// - Returns: Transition source if the item can be resolved.
    func viewerTransitionSource(for ocId: String) -> NCViewerTransitionSource? {
        guard let indexPath = dataSource.getIndexPathMetadata(ocId: ocId) else {
            return nil
        }

        guard let window = collectionView.window else {
            return nil
        }

        collectionView.layoutIfNeeded()

        if collectionView.cellForItem(at: indexPath) == nil {
            collectionView.scrollToItem(
                at: indexPath,
                at: .centeredVertically,
                animated: false
            )

            collectionView.layoutIfNeeded()
        }

        if let cell = collectionView.cellForItem(at: indexPath) as? NCCellMainProtocol,
           let imageView = cell.previewImg,
           let image = imageView.image {
            let sourceFrame = imageView.convert(
                imageView.bounds,
                to: window
            )

            return NCViewerTransitionSource(
                image: image,
                sourceFrame: sourceFrame,
                cornerRadius: imageView.layer.cornerRadius
            )
        }

        guard let attributes = collectionView.layoutAttributesForItem(at: indexPath) else {
            return nil
        }

        let sourceFrame = collectionView.convert(
            attributes.frame,
            to: window
        )

        return NCViewerTransitionSource(
            image: UIImage(),
            sourceFrame: sourceFrame,
            cornerRadius: 6
        )
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard let metadata = self.dataSource.getMetadata(indexPath: indexPath),
              metadata.classFile != NKTypeClassFile.url.rawValue,
              !isEditMode
        else {
            return nil
        }
        let identifier = indexPath as NSCopying
        var image = utility.getImage(ocId: metadata.ocId, etag: metadata.etag, ext: global.previewExt1024, userId: metadata.userId, urlBase: metadata.urlBase)
        let cell = collectionView.cellForItem(at: indexPath)

        if image == nil {
            if cell is NCListCell {
                image = (cell as? NCListCell)?.imageItem.image
            } else if cell is NCGridCell {
                image = (cell as? NCGridCell)?.imageItem.image
            } else if cell is NCPhotoCell {
                image = (cell as? NCPhotoCell)?.imageItem.image
            }
        }

        return UIContextMenuConfiguration(identifier: identifier, previewProvider: {
            return nil
        }, actionProvider: { _ in
            let contextMenu = NCContextMenuMain(metadata: metadata.detachedCopy(), viewController: self, controller: self.controller, sender: cell)
            return contextMenu.viewMenu()
        })
    }

    func collectionView(_ collectionView: UICollectionView, willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration, animator: UIContextMenuInteractionCommitAnimating) {
        animator.addCompletion {
            if let indexPath = configuration.identifier as? IndexPath {
                self.collectionView(collectionView, didSelectItemAt: indexPath)
            }
        }
    }
}
