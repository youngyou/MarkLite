//
//  File.swift
//  Markdown
//
//  Created by zhubch on 2017/6/20.
//  Copyright © 2017年 zhubch. All rights reserved.
//

import UIKit
import EZSwiftExtensions
import RxSwift
import RxCocoa

let textExtName = ["txt","md"]
let archiveExtName = ["zip"]
let imageExtName = ["png","jpg","jpeg","bmp","tif","pic","gif","heif","heic"]

enum FileType {
    case text
    case other
    case archive
    case image
    case folder
    
    var defaultExtName: String {
        switch self {
        case .text:
            return "md"
        case .image:
            return "png"
        case .archive:
            return "zip"
        default:
            return ""
        }
    }
}

extension Int {
    var readabelSize: String {
        if self > 1024*1024 {
            let size = String(format: "%.2f", Double(self) / 1024.0 / 1024.0)
            return "\(size) MB"
        } else if self > 1024{
            let size = String(format: "%.2f", Double(self) / 1024.0)
            return "\(size) KB"
        }
        return "\(self) B"
    }
}

fileprivate let fileManager = FileManager.default

class File {
    private(set) var name: String
    private(set) var path: String {
        didSet {
            _document = nil
        }
    }
    private(set) var modifyDate = Date()
    private(set) var size = 0
    private(set) var disable = false
    private(set) var type = FileType.text
    private(set) var isExternalFile = false
    private(set) var changed = false
    private(set) weak var parent: File?

    fileprivate(set) static var cloud = File.placeholder(name: /"Cloud")
    fileprivate(set) static var local = File.placeholder(name: /"Local")
    fileprivate(set) static var webdav = File.placeholder(name: /"WebDAV")
    fileprivate(set) static var inbox = File.placeholder(name: /"External")
    fileprivate(set) static var empty = File.placeholder(name: /"Empty")
    fileprivate(set) static var current: File?
    
    var displayName: String {
        return _displayName ?? name.components(separatedBy: ".").first ?? name
    }
    
    var extensionName: String {
        if name.contains(".") {
            return name.components(separatedBy: ".").last ?? ""
        }
        return ""
    }

    var children: [File] {
        return _children
    }
    
    var folders: [File] {
        return _children.filter{ $0.type == .folder }
    }
    
    var visibleFolders: [File] {
        if !expand {
            return []
        }
        var visibleFolders = [File]()
        folders.forEach { folder in
            visibleFolders.append(folder)
            visibleFolders.append(contentsOf: folder.visibleFolders)
        }
        return visibleFolders
    }
    
    var text: String? {
        get {
            return document?.text
        }
        set {
            if newValue != nil && newValue != document?.text {
                document?.text = newValue!
                document?.updateChangeCount(.done)
                changed = true
            }
        }
    }
    
    var expand = false {
        didSet {
            if expand == false {
                self.folders.forEach { $0.expand = false }
            }
        }
    }
        
    var deep: Int {
        if let parent = self.parent {
            return parent.deep + 1
        }
        return 0
    }
    
    var url: URL? {
        if isExternalFile {
            return externalURL
        }
        return URL(fileURLWithPath: path)
    }
    
    var document: Document! {
        if _document == nil && url != nil {
            _document = Document(fileURL: url!)
        }
        return _document!
    }
    
    fileprivate var _children = [File]()
    
    fileprivate var _document: Document?
    
    fileprivate var _displayName: String?
    
    fileprivate var _isOpening = false

    fileprivate lazy var externalURL: URL? = {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return nil
        }
        var stale = false
        let url = try? URL(resolvingBookmarkData: data, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale)
        return url ?? nil
    }()
    
    init(path:String) {
        self.path = path
        self.name = path.components(separatedBy: "/").last ?? ""
        
        if (path.hasPrefix(externalPath) && path != externalPath) {
            isExternalFile = true
        }
        
        if path.count == 0 || path.hasPrefix("@/") {
            disable = true
            type = .folder
            return
        }

        var accessed = false
        if isExternalFile {
            accessed = self.externalURL?.startAccessingSecurityScopedResource() ?? false
        }
        
        defer {
            if accessed {
                self.externalURL?.stopAccessingSecurityScopedResource()
            }
        }
        
        guard let url = self.url, let values = try? url.resourceValues(forKeys: [URLResourceKey.isDirectoryKey,.contentModificationDateKey,.fileSizeKey]) else {
            disable = true
            return
        }
        
        self.name = url.lastPathComponent

        if (values.isDirectory ?? false) {
            type = .folder
        } else if extensionName.count == 0 || textExtName.contains(extensionName) {
             type = .text
        } else if archiveExtName.contains(extensionName) {
            type = .archive
        } else if imageExtName.contains(extensionName) {
            type = .image
        } else {
            type = .other
        }
        
        guard type == .folder else {
            modifyDate = values.contentModificationDate ?? Date()
            size = values.fileSize ?? 0
            return
        }
        guard let subPaths = try? fileManager.contentsOfDirectory(atPath: url.path) else {
            return
        }
        if accessed {
            accessed = false
            self.externalURL?.stopAccessingSecurityScopedResource()
        }
        setupChildren(subPaths)
    }
    
    convenience init(path: String, parent: File) {
        self.init(path: path)
        self.parent = parent
    }
    
    class func placeholder(name: String) -> File {
        let file = File(path: "@/" + name)
        file.disable = true
        file.name = name
        file._displayName = name
        return file
    }
    
    public static func ==(lhs: File, rhs: File?) -> Bool {
        if rhs == nil {
            return false
        }
        if lhs.path.count + rhs!.path.count == 0 {
            return lhs.displayName == rhs!.displayName
        }
        return lhs.path == rhs!.path
    }
    
    func findChild(_ childPath: String) -> File? {
        let searchPath = childPath.replacingOccurrences(of: "/private/var", with: "/var")
        let selfPath = path.replacingOccurrences(of: "/private/var", with: "/var")
        if searchPath == selfPath {
            return self
        }
        if searchPath.hasPrefix(selfPath) {
            for file in _children {
                if let ret = file.findChild(searchPath) {
                    return ret
                }
            }
        }
        return nil
    }
    
    func childAtPath(_ path: String) -> File? {
        if self.path == path {
            return self
        }
        
        for child in children {
            if let c = child.childAtPath(path) {
                return c
            }
        }
        return nil
    }
    
    func appendChild(_ path: String) {
        let file = File(path: path, parent: self)
        _children.append(file)
    }
    
    func reloadChildren() {
        if self == File.cloud {
            let url = URL(fileURLWithPath: path)
            try? fileManager.startDownloadingUbiquitousItem(at: url)
        }

        guard let subPaths = try? fileManager.contentsOfDirectory(atPath: path) else {
            return
        }
        
        setupChildren(subPaths)
    }
    
    func setupChildren(_ subPaths:[String]) {
        var newChildren = subPaths.filter{!($0.hasPrefix(".") || $0.hasPrefix("~"))}.map{ File(path:path + "/" + $0,parent: self) }
        if path == documentPath {
            newChildren.removeAll { $0.path == inboxPath }
        }
        newChildren.forEach { child in
            child._document = _children.first(where: {$0 == child})?._document
        }
        _children = newChildren
    }
    
    func createSubDir(name: String) -> File? {
        let path = (self.path + "/" + name)
        let child = self.childAtPath(path)
        if child != nil {
            return child
        } else {
            try? fileManager.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: nil)
            let file = File(path: path, parent: self)
                  _children.append(file)
            return file
        }
    }
    
    func createDirs(paths: [String]) -> File? {
        var f = self;
        
        for p in paths {
            let nf = f.createSubDir(name: p)
            if nf == nil {
                return nil
            } else {
                f = nf!
            }
        }
        return f
    }
    
    @discardableResult
    func createFile(name: String, contents: Any? = nil, type: FileType) -> File?{
        let ext = type.defaultExtName.count == 0 ? "" : ".\(type.defaultExtName)"
        let path = (self.path + "/" + name + ext).validPath
        if type == .folder {
            try? fileManager.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: nil)
        } else {
            if let data = contents as? Data {
                fileManager.createFile(atPath: path, contents: data, attributes: nil)
            } else if let text = contents as? String {
                let data = text.data(using: .utf8)
                fileManager.createFile(atPath: path, contents: data, attributes: nil)
            } else {
                fileManager.createFile(atPath: path, contents: nil, attributes: nil)
            }
        }
        let file = File(path: path, parent: self)
        _children.append(file)
        return file
    }

    @discardableResult
    func trash() -> Bool {
        do {
            try fileManager.removeItem(atPath: self.path)
        } catch {
            return false
        }
        parent?._children.removeAll { $0 == self }
        return true
    }
    
    @discardableResult
    func move(to newParent: File) -> Bool {
        if newParent == self {
            return false
        }
        if parent != nil && newParent == parent! {
            return false
        }
        let newPath = (newParent.path + "/" + name).validPath
        do {
            try fileManager.moveItem(atPath: path, toPath: newPath)
            parent?._children.removeAll { $0 == self }
            newParent._children.append(self)
            parent = newParent
            path = newPath
        } catch {
            return false
        }
        return true
    }
    
    @discardableResult
    func rename(to newName: String) -> Bool {
        if newName == displayName {
            return false
        }
        guard let parent = parent else { return false }
        let ext = extensionName.count == 0 ? (type.defaultExtName.count == 0 ? "" : ".\(type.defaultExtName)") : ".\(extensionName)"
        let newPath = parent.path + "/" + newName + ext
        if fileManager.fileExists(atPath: newPath) {
            return false
        }
        try? fileManager.moveItem(atPath: path, toPath: newPath)
        path = newPath
        name = newName + ext
        reloadChildren()
        return true
    }
    
    func reopen(_ completion:((Bool)->Void)? = nil) {
        if changed == false {
            completion?(true)
            return
        }
        
        document.close { successed in
            if successed {
                self.document.open(completionHandler: completion)
            } else {
                completion?(false)
            }
        }
    }
    
    func close(_ completion:((Bool)->Void)? = nil) {
        if changed {
            modifyDate = Date()
            if let data = text?.data(using: .utf8) {
                size = data.count
            }
            changed = false
        }
        if document.documentState.contains(.closed) {
            File.current = nil
            completion?(true)
        }
        document.close { successed in
            if successed {
                print("file \(self.displayName) close successed")
                if self == File.current {
                    File.current = nil
                }
            } else {
                print("file \(self.displayName) close failed")
            }
            completion?(successed)
        }
    }
    
    func open(_ completion:((Bool)->Void)? = nil) {
        if document.documentState == .normal {
            File.current = self
            completion?(true)
            return
        }
        if _isOpening {
            completion?(false)
            return
        }
        _isOpening = true
        print("file \(self.displayName) start open")
        document.open { successed in
            self._isOpening = false
            if successed {
                print("file \(self.displayName) open successed")
                File.current = self
            } else {
                print("file \(self.displayName) open failed")
            }
            completion?(successed)
        }
    }
    
}

extension File {
    
    class func loadInbox(_ completion: @escaping (File)->Void) {
        DispatchQueue.global().async {
            let inbox = File(path: externalPath)
            inbox._displayName = /"External"
            inbox.name = /"External"
            File.inbox = inbox
            DispatchQueue.main.sync {
                completion(inbox)
            }
        }
    }
    
    class func loadLocal(_ completion: @escaping (File)->Void) {
        DispatchQueue.global().async {
            let local = File(path: documentPath)
            local._displayName = /"Local"
            local.name = /"Local"
            File.local = local
            DispatchQueue.main.sync {
                completion(local)
            }
        }
    }
    
    class func loadCloud(_ completion: @escaping (File)->Void) {
        DispatchQueue.global().async {
            if fileManager.fileExists(atPath: cloudPath) == false {
                try? fileManager.createDirectory(atPath: cloudPath, withIntermediateDirectories: true, attributes: nil)
            }
            let url = URL(fileURLWithPath: cloudPath)
            try? fileManager.startDownloadingUbiquitousItem(at: url)
            let cloud = File(path: cloudPath)
            if cloudPath.count == 0 {
                cloud.disable = true
            }
            cloud._displayName = /"Cloud"
            cloud.name = /"Cloud"
            File.cloud = cloud
            DispatchQueue.main.sync {
                 completion(cloud)
            }
        }
    }
}





