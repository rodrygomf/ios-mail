//
//  Standalone.swift
//  ProtonMail - Created on 14/03/2019.
//
//
//  Copyright (c) 2019 Proton Technologies AG
//
//  This file is part of ProtonMail.
//
//  ProtonMail is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  ProtonMail is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with ProtonMail.  If not, see <https://www.gnu.org/licenses/>.
    

import Foundation

/// ViewModel object representing one Message in a thread
class MessageViewModel: NSObject {
    
    internal enum Divisions: Int { // TODO: refactor with OptionSet
        // each division is perpresented by a single row in tableView
        case header = 0, attachments, remoteContent, body, expiration
    }
    
    internal let messageID: String
    @objc internal dynamic var body: String?
    @objc internal dynamic var header: HeaderData
    @objc internal dynamic var attachments: [AttachmentInfo]
    internal let expiration: Date?
    
    @objc internal dynamic var heightOfHeader: CGFloat = 0.0
    @objc internal dynamic var heightOfBody: CGFloat = 0.0
    @objc internal dynamic var heightOfAttachments: CGFloat = 0.0
    
    @objc internal dynamic var divisionsCount: Int
    private(set) var divisions: [Divisions] {
        didSet { self.divisionsCount = divisions.count }
    }
    
    @objc private(set) dynamic var remoteContentModeObservable: WebContents.RemoteContentPolicy.RawValue
    internal var remoteContentMode: WebContents.RemoteContentPolicy {
        get { return WebContents.RemoteContentPolicy(rawValue: self.remoteContentModeObservable)! }
        set {
            self.remoteContentModeObservable = newValue.rawValue
            if newValue == .allowed {
                self.divisions = self.divisions.filter { $0 != .remoteContent}
            } else if !self.divisions.contains(.remoteContent), let bodyIndex = self.divisions.firstIndex(of: .body) {
                self.divisions.insert(.remoteContent, at: bodyIndex)
            }
        }
    }
    
    convenience init(message: Message) {
        self.init(message: message, embeddingImages: true)
    }
    
    init(message: Message, embeddingImages: Bool) {
        // 0. expiration
        self.expiration = message.expirationTime
        let expired = (self.expiration ?? .distantFuture).compare(Date()) == .orderedAscending
        
        // 1. header
        self.header = HeaderData(message: message)
        
        // 2. body
        var body: String? = nil
        do {
            body = try message.decryptBodyIfNeeded() ?? LocalString._unable_to_decrypt_message
        } catch let ex as NSError {
            PMLog.D("purifyEmailBody error : \(ex)")
            body = message.bodyToHtml()
        }
        if expired {
            body = LocalString._message_expired
        }
        if !message.isDetailDownloaded {
            body = nil
        }
        self.body = body
        
        // 3. attachments
        var atts: [AttachmentInfo] = (message.attachments.allObjects as? [Attachment])?.map(AttachmentNormal.init) ?? [] // normal
        atts.append(contentsOf: message.tempAtts ?? []) // inline
        self.attachments = atts
        
        // 4. remote content policy
        self.remoteContentModeObservable = sharedUserDataService.autoLoadRemoteImages ? WebContents.RemoteContentPolicy.allowed.rawValue : WebContents.RemoteContentPolicy.disallowed.rawValue
        
        // 5. divisions
        self.divisions = []
        self.divisions.append(.header)
        if self.expiration != nil {
            self.divisions.append(.expiration)
        }
        if !self.attachments.isEmpty, !expired  {
            self.divisions.append(.attachments)
        }
        self.divisions.append(.body)
        
        // others
        self.messageID = message.messageID
        self.divisionsCount = self.divisions.count
        
        super.init()
        
        // there was a method embedding images here, revert and debug in case of problems
        
        if let expirationOffset = message.expirationTime?.timeIntervalSinceNow, expirationOffset > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(Int(expirationOffset))) { [weak self, message] in
                self?.reload(from: message)
            }
        }
    }
    
    internal func reload(from message: Message) {
        let temp = MessageViewModel(message: message, embeddingImages: false)

        self.header = temp.header
        self.attachments = temp.attachments
        self.divisions = temp.divisions
        
        DispatchQueue.global().async {
            let hasImage = (temp.body ?? "").hasImage() // this method is slow
            DispatchQueue.main.async {
                if hasImage && !sharedUserDataService.autoLoadRemoteImages { // we only care if there is remote content and loading is not allowed
                    self.remoteContentMode = .disallowed
                }
            }
        }
        
        if let body = temp.body {
            self.showEmbedImage(message, body: body)
        }
    }

    private func showEmbedImage(_ message: Message, body: String) {
        guard message.isDetailDownloaded,
            let allAttachments = message.attachments.allObjects as? [Attachment],
            case let atts = allAttachments.filter({ $0.inline() && $0.contentID()?.isEmpty == false }),
            !atts.isEmpty else
        {
            if self.body != body {
                self.body = body
            }
            return
        }
        
        let checkCount = atts.count
        let queue: DispatchQueue = .global(qos: .userInteractive)
        
        DispatchQueue.global(qos: .userInitiated).async {
            var strings: [String:String] = [:]
            for att in atts {
                att.base64AttachmentData { [weak self] based64String in
                    let work = DispatchWorkItem {
                        if !based64String.isEmpty {
                            strings["src=\"cid:\(att.contentID()!)\""] = "src=\"data:\(att.mimeType);base64,\(based64String)\""
                        }
                        
                        if checkCount == strings.count {
                            var updatedBody = body
                            for (cid, base64) in strings {
                                updatedBody = updatedBody.stringBySetupInlineImage(cid, to: base64)
                            }
                            
                            DispatchQueue.main.async {
                                self?.body = updatedBody
                            }
                        }
                    }
                    queue.async(execute: work)
                }
            }
        }
    }
}
