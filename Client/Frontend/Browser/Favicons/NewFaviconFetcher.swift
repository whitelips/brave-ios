// Copyright 2020 The Brave Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import Foundation
import Data
import Storage
import Shared
import SwiftyJSON
import Fuzi
import SDWebImage

private let log = Logger.browserLogger

/// Handles obtaining favicons for URLs from local files, database or internet
class NewFaviconFetcher {
    /// The size requirement for the favicon
    enum Kind {
        /// Load favicons marked as `apple-touch-icon`.
        ///
        /// Usage: NTP, Favorites
        case largeIcon
        /// Load smaller favicons
        ///
        /// Usage: History, Search, Tab Tray
        case favicon
        
        fileprivate var iconType: IconType {
            switch self {
            case .largeIcon: return .appleIcon
            case .favicon: return .icon
            }
        }
    }
    
    struct FaviconAttributes {
        var image: UIImage?
        var backgroundColor: UIColor?
        var contentMode: UIView.ContentMode = .scaleAspectFit
        var includePadding: Bool = false
    }
    
    private let url: URL
    private let domain: Domain
    private let kind: Kind
    static var htmlParsingUserAgent: String?
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 5
        if let userAgent = NewFaviconFetcher.htmlParsingUserAgent {
            configuration.httpAdditionalHeaders = ["User-Agent": userAgent]
        }
        return URLSession(configuration: configuration, delegate: nil, delegateQueue: .main)
    }()
    private var dataTasks: [URLSessionDataTask] = []
    private var imageOps: [SDWebImageOperation] = []
    
    static let defaultFaviconImage = #imageLiteral(resourceName: "defaultFavicon")
    
    init(siteURL: URL, kind: Kind, domain: Domain? = nil) {
        self.url = siteURL
        self.kind = kind
        self.domain = domain ?? Domain.getOrCreate(
            forUrl: siteURL,
            persistent: !PrivateBrowsingManager.shared.isPrivateBrowsing
        )
    }
    
    deinit {
        dataTasks.forEach { $0.cancel() }
        imageOps.forEach { $0.cancel() }
    }
    
    private func faviconOnFileMatchesFetchKind(_ favicon: FaviconMO?) -> Bool {
        guard let favicon = favicon else { return false }
        return favicon.type == Int16(kind.iconType.rawValue) ||
            IconType(rawValue: Int(favicon.type))?.isPreferredTo(kind.iconType) == true
    }
    
    func load(_ completion: @escaping (FaviconAttributes) -> Void) {
        // Priority order for favicons:
        //   1. User installed icons (via using custom theme for example)
        //   2. Icons bundled in the app
        //   3. Fetched favicon from the website given the size requirement
        //   4. Default letter + background color
        if let icon = customIcon {
            completion(icon)
            return
        }
        let matchesFetchKind = faviconOnFileMatchesFetchKind(domain.favicon)
        if let icon = bundledIcon, domain.favicon == nil || !matchesFetchKind {
            completion(icon)
            return
        }
        fetchIcon(completion)
    }
    
    // MARK: - Custom Icons
    
    private var customIcon: FaviconAttributes? {
        guard let folder = FileManager.default.getOrCreateFolder(name: NTPDownloader.faviconOverridesDirectory),
            let baseDomain = url.baseDomain else {
                return nil
        }
        let backgroundName = baseDomain + NTPDownloader.faviconOverridesBackgroundSuffix
        let backgroundPath = folder.appendingPathComponent(backgroundName)
        do {
            let colorString = try String(contentsOf: backgroundPath)
            let colorFromHex = UIColor(colorString: colorString)
            
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent(baseDomain).path) {
                let imagePath = folder.appendingPathComponent(baseDomain)
                if let image = UIImage(contentsOfFile: imagePath.path) {
                    return FaviconAttributes(
                        image: image,
                        backgroundColor: colorFromHex
                    )
                }
                return nil
            }
        } catch {
            return nil
        }
        return nil
    }
    
    // MARK: - Bundled Icons
    
    private var bundledIcon: FaviconAttributes? {
        // Problem: Sites like amazon exist with .ca/.de and many other tlds.
        // Solution: They are stored in the default icons list as "amazon" instead of "amazon.com" this allows us to have favicons for every tld."
        // Here, If the site is in the multiRegionDomain array look it up via its second level domain (amazon) instead of its baseDomain (amazon.com)
        let hostName = url.hostSLD
        var bundleIcon: (color: UIColor, url: String)?
        if Self.multiRegionDomains.contains(hostName), let icon = Self.bundledIcons[hostName] {
            bundleIcon = icon
        } else if let name = url.baseDomain, let icon = Self.bundledIcons[name] {
            bundleIcon = icon
        }
        guard let icon = bundleIcon, let image = UIImage(contentsOfFile: icon.url) else {
            return nil
        }
        let scale = self.kind == .largeIcon ? 40.0 : 20.0
        return FaviconAttributes(
            image: image.createScaled(CGSize(width: scale, height: scale)),
            backgroundColor: icon.color,
            contentMode: .center
        )
    }
    
    private static let multiRegionDomains = ["craigslist", "google", "amazon"]
    private static let bundledIcons: [String: (color: UIColor, url: String)] = {
        guard let filePath = Bundle.main.path(forResource: "top_sites", ofType: "json") else {
            log.error("Failed to get bundle path for \"top_sites.json\"")
            return [:]
        }
        do {
            let file = try Data(contentsOf: URL(fileURLWithPath: filePath))
            let json = JSON(file)
            var icons: [String: (color: UIColor, url: String)] = [:]
            json.forEach({
                guard let url = $0.1["domain"].string, let color = $0.1["background_color"].string?.lowercased(),
                    var path = $0.1["image_url"].string else {
                        return
                }
                path = path.replacingOccurrences(of: ".png", with: "")
                let filePath = Bundle.main.path(forResource: "TopSites/" + path, ofType: "png")
                if let filePath = filePath {
                    if color == "#fff" {
                        icons[url] = (UIColor.white, filePath)
                    } else {
                        icons[url] = (UIColor(colorString: color.replacingOccurrences(of: "#", with: "")), filePath)
                    }
                }
            })
            return icons
        } catch {
            log.error("Failed to get default icons at \(filePath): \(error.localizedDescription)")
            return [:]
        }
    }()
     
    // MARK: - Fetched Icons
    
    private func downloadIcon(url: URL, completion: @escaping (UIImage?) -> Void) {
        // Fetch favicon directly
        var imageOperation: SDWebImageOperation?
        
        let onProgress: ImageCacheProgress = { receivedSize, expectedSize, _ in
            if receivedSize > FaviconHandler.maximumFaviconSize || expectedSize > FaviconHandler.maximumFaviconSize {
                imageOperation?.cancel()
            }
        }
        
        let onCompletion: ImageCacheCompletion = { [weak self] image, _, _, cacheType, url in
            guard let self = self else { return }
            let favicon = Favicon(url: url.absoluteString, date: Date(), type: self.kind.iconType)
            
            if let image = image {
                favicon.width = Int(image.size.width)
                favicon.height = Int(image.size.height)
                FaviconMO.add(favicon, forSiteUrl: self.url)
                
                DispatchQueue.main.async {
                    completion(image)
                }
            } else {
                favicon.width = 0
                favicon.height = 0
                
                DispatchQueue.main.async {
                    completion(nil)
                }
            }
        }
        
        imageOperation = WebImageCacheWithNoPrivacyProtectionManager.shared.load(from: url, progress: onProgress, completion: onCompletion)
        if let op = imageOperation {
            imageOps.append(op)
        }
    }
    
    private func fetchIcon(_ completion: @escaping (FaviconAttributes) -> Void) {
        // Attempt to find favicon cached for the given Domain
        if let favicon = domain.favicon, let urlString = favicon.url, let url = URL(string: urlString) {
            // Verify that the favicon we have on file is what we want to pull
            // If not, we will just default to monogram to avoid blurry images
            if faviconOnFileMatchesFetchKind(favicon) {
                downloadIcon(url: url) { [weak self] image in
                    guard let self = self else { return }
                    if let image = image {
                        self.isIconBackgroundTransparentAroundEdges(image) { isTransparent in
                            completion(FaviconAttributes(image: image, includePadding: isTransparent))
                        }
                    } else {
                        completion(self.monogramFavicon)
                    }
                }
            } else {
                completion(self.monogramFavicon)
            }
            return
        }
        // For large icon pulls (Favorites), if we do not have any cached
        // or recorded favicon on file, we will attempt to pull the HTML of the
        // page and parse out Favicons manually.
        if kind == .largeIcon {
            // Check attributes cache for HTML parsing. If a page does not
            // give us any favicon it's likely not going to during this session
            //
            // Possible TODO: Perhaps fallback to `/favicon.ico` even though
            // `largeIcon` requests will not use it so we can at least return
            // monogram icon attributes immediately
            if let parsedFavicon = Self.attributesForHTMLCache[self.url] {
                completion(parsedFavicon)
            } else {
                parseHTMLForFavicons(for: url) { [weak self] attributes in
                    guard let self = self else { return }
                    Self.attributesForHTMLCache[self.url] = attributes
                    completion(attributes)
                }
            }
        } else {
            completion(self.monogramFavicon)
        }
    }
    
    private static var attributesForHTMLCache: [URL: FaviconAttributes] = [:]
    
    /// Download the HTML of a page and use that to parse favicons out of the
    /// `<head>` tags.
    ///
    /// - Note: Ensure any changes regarding icon fetching/scoring is also
    /// updated in `MetadataHelper.js` to ensure both methods of fetching
    /// favicons remain consistent.
    private func parseHTMLForFavicons(for url: URL, _ completion: @escaping (FaviconAttributes) -> Void) {
        let pageTask = session.dataTask(with: url) { [weak self] (data, response, error) in
            guard let self = self else { return }
            guard let data = data, error == nil, let root = try? HTMLDocument(data: data) else {
                DispatchQueue.main.async {
                    completion(self.monogramFavicon)
                }
                return
            }
            // Ensure page is reloaded to final landing page before looking for
            // favicons
            var reloadUrl: URL?
            for meta in root.xpath("//head/meta") {
                if let refresh = meta["http-equiv"], refresh == "Refresh",
                    let content = meta["content"],
                    let index = content.range(of: "URL="),
                    let url = NSURL(string: String(content.suffix(from: index.upperBound))) {
                    reloadUrl = url as URL
                }
            }
            
            if let url = reloadUrl {
                self.parseHTMLForFavicons(for: url, completion)
                return
            }
            
            let xpath = self.kind == .largeIcon ?
                "//head//link[contains(@rel, 'apple-touch-icon')]" :
                "//head//link[contains(@rel, 'icon')]"
            var highestScore: Double = -1.0
            var icon: Favicon?
            // Look for a favicon with the sizes closest to the goal
            let goal = self.kind == .largeIcon ? 180.0 * 180.0 : 48 * 48
            for link in root.xpath(xpath) {
                guard let href = link["href"] else { continue }
                let size = link["sizes"]?
                    .split(separator: "x")
                    .compactMap { Double($0) }
                    .reduce(0, { $0 * $1 }) ?? 0.0
                let score = 1.0 - (abs(size - goal)) / goal
                
                if score > highestScore, let faviconURL = URL(string: href, relativeTo: url) {
                    highestScore = score
                    icon = Favicon(url: faviconURL.absoluteString, date: Date(), type: self.kind.iconType)
                }
            }
            
            guard let favicon = icon, let faviconURL = URL(string: favicon.url) else {
                DispatchQueue.main.async {
                    completion(self.monogramFavicon)
                }
                return
            }
            
            self.downloadIcon(url: faviconURL) { [weak self] image in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    if let image = image {
                        completion(FaviconAttributes(image: image))
                    } else {
                        completion(self.monogramFavicon)
                    }
                }
            }
        }
        pageTask.resume()
        self.dataTasks.append(pageTask)
    }
    
    // MARK: - Monogram Favicons
    
    private var monogramFavicon: FaviconAttributes {
        func backgroundColor() -> UIColor {
            guard let hash = url.baseDomain?.hashValue else {
                return UIColor.Photon.grey50
            }
            let index = abs(hash) % (UIConstants.defaultColorStrings.count - 1)
            let colorHex = UIConstants.defaultColorStrings[index]
            return UIColor(colorString: colorHex)
        }
        return FaviconAttributes(
            image: nil,
            backgroundColor: backgroundColor()
        )
    }
    
    // MARK: - Misc
    
    /// Determines if the downloaded image should be padded because its edges
    /// are for the most part transparent
    private func isIconBackgroundTransparentAroundEdges(_ icon: UIImage, completion: @escaping (_ isTransparent: Bool) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            guard let cgImage = icon.createScaled(CGSize(width: 48, height: 48)).cgImage else {
                DispatchQueue.main.async {
                    completion(false)
                }
                return
            }
            let alphaInfo = cgImage.alphaInfo
            let hasAlphaChannel = alphaInfo == .first || alphaInfo == .last ||
                alphaInfo == .premultipliedFirst || alphaInfo == .premultipliedLast
            if hasAlphaChannel {
                let dataProvider = cgImage.dataProvider!
                let length = CFDataGetLength(dataProvider.data)
                // Sample the image edges to determine if it has tranparent pixels
                if let data = CFDataGetBytePtr(dataProvider.data) {
                    // Scoring system: if the pixel alpha is 1.0, score -1 otherwise
                    // score +1. If the score at the end of scanning all edge pixels
                    // is higher than 0, then the majority of the image's edges
                    // are transparent and the image should be padded slightly
                    var score: Int = 0
                    func updateScore(x: Int, y: Int) {
                        let location = ((Int(icon.size.width) * y) + x) * 4
                        guard location + 3 < length else { return }
                        let alpha = data[location + 3]
                        if alpha == 255 {
                            score -= 1
                        } else {
                            score += 1
                        }
                    }
                    for x in 0..<Int(icon.size.width) {
                        updateScore(x: x, y: 0)
                    }
                    for x in 0..<Int(icon.size.width) {
                        updateScore(x: x, y: Int(icon.size.height))
                    }
                    // We've already scanned the first and last pixel during
                    // top/bottom pass
                    for y in 1..<Int(icon.size.height)-1 {
                        updateScore(x: 0, y: y)
                    }
                    for y in 1..<Int(icon.size.height)-1 {
                        updateScore(x: Int(icon.size.width), y: y)
                    }
                    DispatchQueue.main.async {
                        completion(score > 0)
                    }
                }
            } else {
                DispatchQueue.main.async {
                    completion(false)
                }
            }
        }
    }
}

private var AssociatedObjectHandle: UInt8 = 0

extension UIImageView {
    
    private var faviconFetcher: NewFaviconFetcher? {
        get { objc_getAssociatedObject(self, &AssociatedObjectHandle) as? NewFaviconFetcher }
        set { objc_setAssociatedObject(self, &AssociatedObjectHandle, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
    
    func loadFavicon(for siteURL: URL, kind: NewFaviconFetcher.Kind, domain: Domain? = nil) {
        faviconFetcher = NewFaviconFetcher(siteURL: siteURL, kind: kind, domain: domain)
        faviconFetcher?.load { [weak self] attributes in
            guard let self = self else { return }
            self.image = attributes.image ?? NewFaviconFetcher.defaultFaviconImage
            self.backgroundColor = attributes.backgroundColor ?? .white
            self.contentMode = attributes.contentMode
        }
    }
}