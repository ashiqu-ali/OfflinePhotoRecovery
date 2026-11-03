import Foundation

/// Turns a backup domain and path into a human label such as "Camera Roll" or "WhatsApp".
public enum SourceClassifier {
    public static let cameraRoll = "Camera Roll"
    public static let thumbnails = "Photo Thumbnails (low-res)"
    public static let messages = "Messages Attachments"

    private static let knownApps: [(bundle: String, name: String)] = [
        ("net.whatsapp.WhatsAppSMB", "WhatsApp Business"),
        ("net.whatsapp.WhatsApp", "WhatsApp"),
        ("ph.telegra.Telegraph", "Telegram"),
        ("org.whispersystems.signal", "Signal"),
        ("com.burbn.instagram", "Instagram"),
        ("com.facebook.Facebook", "Facebook"),
        ("com.facebook.Messenger", "Messenger"),
        ("com.toyopagroup.picaboo", "Snapchat"),
        ("com.zhiliaoapp.musically", "TikTok"),
        ("com.atebits.Tweetie2", "X (Twitter)"),
        ("com.tencent.xin", "WeChat"),
        ("com.viber", "Viber"),
        ("jp.naver.line", "LINE"),
        ("com.skype.skype", "Skype"),
        ("com.google.photos", "Google Photos"),
        ("com.google.Gmail", "Gmail"),
        ("com.getdropbox.Dropbox", "Dropbox"),
        ("com.microsoft.skydrive", "OneDrive"),
        ("com.apple.mobileslideshow", "Photos"),
        ("com.apple.MobileSMS", "Messages"),
        ("com.apple.mobilenotes", "Notes"),
        ("com.apple.notes", "Notes"),
        ("com.apple.mobilemail", "Mail"),
        ("com.apple.camera", "Camera"),
    ]

    public static func source(domain: String, path: String) -> String {
        switch domain {
        case "CameraRollDomain":
            if path.hasPrefix("Media/DCIM/") { return cameraRoll }
            if path.contains("/Thumbnails/") { return thumbnails }
            if path.contains("/Mutations/") { return "Edited Photo Versions" }
            if path.contains("/CPLAssets/") || path.hasPrefix("Media/PhotoData/CPL/") { return "iCloud Photos Cache" }
            if path.hasPrefix("Media/PhotoStreamsData") { return "Shared Albums" }
            return "Photos App Data"
        case "MediaDomain":
            if path.hasPrefix("Library/SMS/Attachments") { return messages }
            if path.hasPrefix("Media/PhotoStreamsData") { return "Shared Albums" }
            if path.hasPrefix("Media/CloudAssets") || path.hasPrefix("Media/LoFiCloudAssets") { return "iCloud Photos Cache" }
            if path.hasPrefix("Media/Downloads") { return "Downloads" }
            if path.hasPrefix("Media/Photos/") { return "Photos Synced from a Computer" }
            return "Other Media"
        case "HomeDomain":
            if path.hasPrefix("Library/SMS/") { return messages }
            return "iPhone System Files"
        default:
            break
        }
        for prefix in ["AppDomainGroup-", "AppDomainPlugin-", "AppDomain-", "SysSharedContainerDomain-", "SysContainerDomain-"]
        where domain.hasPrefix(prefix) {
            return appName(for: String(domain.dropFirst(prefix.count)))
        }
        return domain
    }

    static func appName(for identifier: String) -> String {
        var id = identifier
        for prefix in ["group.", "systemgroup."] where id.hasPrefix(prefix) { id.removeFirst(prefix.count) }
        for app in knownApps where id == app.bundle || id.hasPrefix(app.bundle + ".") { return app.name }
        return id
    }
}
