//
//  Bundle+Version.swift
//  GitLabMonitor
//

import Foundation

extension Bundle {
    var appVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
    }

    var appDisplayName: String {
        (infoDictionary?["CFBundleDisplayName"] as? String)
            ?? (infoDictionary?["CFBundleName"] as? String)
            ?? menuProductName
    }

    var feedbackURL: URL {
        let components = URLComponents(string: "https://www.georgegillams.co.uk/gitlab-monitor-feedback")!
        return components.url!
    }

    var authorURL: URL {
        var components = URLComponents(string: "https://www.georgegillams.co.uk/")!
        components.queryItems = [URLQueryItem(name: "utm_source", value: "gitlab-monitor")]
        return components.url!
    }

    var isLocalDevelopment: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    var menuProductName: String {
        "GitLab Monitor"
    }

    var menuBuildLabel: String {
        isLocalDevelopment ? "local development" : appVersion
    }
}
