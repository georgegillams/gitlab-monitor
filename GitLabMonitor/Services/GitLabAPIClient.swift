//
//  GitLabAPIClient.swift
//  GitLabMonitor
//

import Foundation

enum GitLabAPIError: LocalizedError {
    case invalidURL
    case httpStatus(Int, String?)
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid GitLab URL"
        case .httpStatus(let code, let body):
            if let body, !body.isEmpty {
                return "HTTP \(code): \(body)"
            }
            return "HTTP \(code)"
        case .decoding(let error):
            return "Could not parse response: \(error.localizedDescription)"
        }
    }
}

actor GitLabAPIClient {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Ephemeral session: GitLab responses stay in memory. The delegate refuses any
        // redirect whose host is not the host we originally requested.
        self.session = URLSession(
            configuration: configuration,
            delegate: GitLabSameHostRedirectDelegate(),
            delegateQueue: nil
        )
    }

    func fetchAuthoredOpenMergeRequests(
        instance: GitLabInstanceConfig,
        token: String,
        sortOrder: MergeRequestSortOrder
    ) async throws -> [MergeRequestItem] {
        let mrs = try await listMergeRequests(
            baseURL: instance.normalizedBaseURL,
            token: token,
            sortOrder: sortOrder
        )
        var results: [MergeRequestItem] = []

        try await withThrowingTaskGroup(of: MergeRequestItem?.self) { group in
            for mr in mrs {
                group.addTask {
                    try await self.enrich(
                        mr: mr,
                        instance: instance,
                        token: token
                    )
                }
            }
            for try await item in group {
                if let item {
                    results.append(item)
                }
            }
        }

        return results.sorted {
            if $0.projectPath == $1.projectPath {
                return $0.iid > $1.iid
            }
            return $0.projectPath.localizedCaseInsensitiveCompare($1.projectPath) == .orderedAscending
        }
    }

    // MARK: - Private

    private struct APIMergeRequest: Decodable {
        let id: Int
        let iid: Int
        let title: String
        let web_url: String?
        let created_at: String?
        let updated_at: String?
        let project_id: Int
        let references: References?
        let head_pipeline: PipelineRef?
        let pipeline: PipelineRef?

        struct References: Decodable {
            let full: String?
        }

        struct PipelineRef: Decodable {
            let id: Int?
            let project_id: Int?
            let status: String?
        }

        var pipelineID: Int? {
            head_pipeline?.id ?? pipeline?.id
        }

        var projectPath: String {
            if let full = references?.full, let bang = full.firstIndex(of: "!") {
                return String(full[..<bang])
            }
            return "project/\(project_id)"
        }
    }

    private struct APIPipeline: Decodable {
        let id: Int
        let project_id: Int?
    }

    private struct APIJob: Decodable {
        let id: Int
        let name: String
        let stage: String
        let status: String
        let web_url: String?
    }

    private struct APIApprovals: Decodable {
        let approved_by: [ApproverWrapper]?
        let approvals_required: Int?
        let approvals_left: Int?
        let user_has_approved: Bool?

        struct ApproverWrapper: Decodable {
            let user: ApproverUser?
        }

        struct ApproverUser: Decodable {
            let name: String?
            let username: String?
        }
    }

    private func listMergeRequests(
        baseURL: String,
        token: String,
        sortOrder: MergeRequestSortOrder
    ) async throws -> [APIMergeRequest] {
        guard var components = URLComponents(string: "\(baseURL)/api/v4/merge_requests") else {
            throw GitLabAPIError.invalidURL
        }
        // The page is capped at 50, so the query field and direction have to match the setting.
        components.queryItems = [
            URLQueryItem(name: "scope", value: "created_by_me"),
            URLQueryItem(name: "state", value: "opened"),
            URLQueryItem(name: "per_page", value: "50"),
            URLQueryItem(name: "order_by", value: sortOrder.gitLabOrderBy),
            URLQueryItem(name: "sort", value: sortOrder.gitLabSort)
        ]
        guard let url = components.url else { throw GitLabAPIError.invalidURL }
        return try await get(url, baseURL: baseURL, token: token)
    }

    private func enrich(
        mr: APIMergeRequest,
        instance: GitLabInstanceConfig,
        token: String
    ) async throws -> MergeRequestItem {
        async let stages = fetchStages(
            baseURL: instance.normalizedBaseURL,
            mr: mr,
            token: token
        )
        async let approvals = fetchApprovals(
            baseURL: instance.normalizedBaseURL,
            projectID: mr.project_id,
            iid: mr.iid,
            token: token
        )

        return MergeRequestItem(
            id: "\(instance.id.uuidString)-\(mr.id)",
            instanceID: instance.id,
            instanceLabel: instance.displayLabel,
            projectID: mr.project_id,
            iid: mr.iid,
            title: mr.title,
            projectPath: mr.projectPath,
            webURL: sameHostURL(mr.web_url, baseURL: instance.normalizedBaseURL),
            stages: try await stages,
            approvals: try await approvals,
            createdAt: Self.parseGitLabDate(mr.created_at),
            updatedAt: Self.parseGitLabDate(mr.updated_at)
        )
    }

    private struct ResolvedPipeline {
        let id: Int
        let projectID: Int
    }

    private func fetchStages(
        baseURL: String,
        mr: APIMergeRequest,
        token: String
    ) async throws -> [PipelineStage] {
        guard let pipeline = try await resolvePipeline(baseURL: baseURL, mr: mr, token: token) else {
            return []
        }
        let jobs = try await fetchJobs(
            baseURL: baseURL,
            projectID: pipeline.projectID,
            pipelineID: pipeline.id,
            token: token
        )
        let reported = await reportedStages(
            baseURL: baseURL,
            fullPath: mr.projectPath,
            projectID: mr.project_id,
            pipelineID: pipeline.id,
            token: token
        )
        return stages(from: jobs, reported: reported, baseURL: baseURL)
    }

    /// The merge request list often omits `head_pipeline`. Approvals still load
    /// from the project id and iid; stages need a pipeline, so ask for this MR's pipelines.
    private func resolvePipeline(
        baseURL: String,
        mr: APIMergeRequest,
        token: String
    ) async throws -> ResolvedPipeline? {
        if let id = mr.pipelineID {
            let projectID = mr.head_pipeline?.project_id ?? mr.pipeline?.project_id ?? mr.project_id
            return ResolvedPipeline(id: id, projectID: projectID)
        }

        guard var components = URLComponents(
            string: "\(baseURL)/api/v4/projects/\(mr.project_id)/merge_requests/\(mr.iid)/pipelines"
        ) else {
            throw GitLabAPIError.invalidURL
        }
        // Newest pipeline is first. One result is enough for the current head.
        components.queryItems = [URLQueryItem(name: "per_page", value: "1")]
        guard let url = components.url else { throw GitLabAPIError.invalidURL }
        let pipelines: [APIPipeline]
        do {
            pipelines = try await get(url, baseURL: baseURL, token: token)
        } catch let error as GitLabAPIError {
            // Pipelines aren't available for this MR. Leave its stages empty.
            if case .httpStatus(let code, _) = error, code == 403 || code == 404 {
                return nil
            }
            throw error
        }
        guard let latest = pipelines.max(by: { $0.id < $1.id }) else { return nil }
        return ResolvedPipeline(id: latest.id, projectID: latest.project_id ?? mr.project_id)
    }

    private func fetchJobs(
        baseURL: String,
        projectID: Int,
        pipelineID: Int,
        token: String
    ) async throws -> [APIJob] {
        var page = 1
        var collected: [APIJob] = []
        // The jobs API defaults to 20 per page, newest first. A pipeline with more
        // jobs than that would drop earlier stages.
        for _ in 0..<15 {
            guard var components = URLComponents(
                string: "\(baseURL)/api/v4/projects/\(projectID)/pipelines/\(pipelineID)/jobs"
            ) else {
                throw GitLabAPIError.invalidURL
            }
            components.queryItems = [
                URLQueryItem(name: "include_retried", value: "false"),
                URLQueryItem(name: "per_page", value: "100"),
                URLQueryItem(name: "page", value: String(page))
            ]
            guard let url = components.url else { throw GitLabAPIError.invalidURL }
            let pageResult: (value: [APIJob], nextPage: Int?) = try await fetch(url, baseURL: baseURL, token: token)
            collected.append(contentsOf: pageResult.value)
            guard let nextPage = pageResult.nextPage, nextPage > page else { break }
            page = nextPage
        }
        return collected
    }

    /// A stage GitLab has already summarized. Job ids are only a fallback order.
    private struct ReportedStage {
        let name: String
        let status: PipelineStageStatus
    }

    private func stages(from jobs: [APIJob], reported: [ReportedStage], baseURL: String) -> [PipelineStage] {
        var earliestJobID: [String: Int] = [:]
        var jobsByStage: [String: [PipelineJob]] = [:]

        // Retried attempts are omitted. The remaining jobs are the latest of each name.
        let orderedJobs = jobs.sorted { $0.id < $1.id }
        for job in orderedJobs {
            if earliestJobID[job.stage] == nil {
                earliestJobID[job.stage] = job.id
            }
            jobsByStage[job.stage, default: []].append(
                PipelineJob(
                    id: job.id,
                    name: job.name,
                    status: PipelineStageStatus.fromGitLabStatus(job.status),
                    webURL: sameHostURL(job.web_url, baseURL: baseURL)
                )
            )
        }

        var statusByName: [String: PipelineStageStatus] = [:]
        var names: [String] = []
        for stage in reported where statusByName[stage.name] == nil && jobsByStage[stage.name] != nil {
            statusByName[stage.name] = stage.status
            names.append(stage.name)
        }
        let missing = earliestJobID.keys.filter { statusByName[$0] == nil }.sorted {
            (earliestJobID[$0] ?? 0) < (earliestJobID[$1] ?? 0)
        }
        names.append(contentsOf: missing)

        return names.map { name in
            PipelineStage(
                name: name,
                status: statusByName[name] ?? .unknown,
                jobs: jobsByStage[name] ?? []
            )
        }
    }

    /// GitLab draws stages left to right by `ci_stages.position` and stores each stage's status.
    private static let stageStatusQuery = """
    query($fullPath: ID!, $id: CiPipelineID!) {
      project(fullPath: $fullPath) {
        pipeline(id: $id) {
          stages(first: 100) {
            nodes { name status }
          }
        }
      }
    }
    """

    private struct StageStatusResponse: Decodable {
        struct Envelope: Decodable {
            struct Project: Decodable {
                struct Pipeline: Decodable {
                    struct Stages: Decodable {
                        struct Node: Decodable {
                            let name: String?
                            let status: String?
                        }

                        let nodes: [Node]?
                    }

                    let stages: Stages?
                }

                let pipeline: Pipeline?
            }

            let project: Project?
        }

        let data: Envelope?
    }

    private func reportedStages(
        baseURL: String,
        fullPath: String,
        projectID: Int,
        pipelineID: Int,
        token: String
    ) async -> [ReportedStage] {
        // `project/<id>` is the stand-in used when the MR list has no path.
        guard fullPath != "project/\(projectID)" else { return [] }
        guard let url = URL(string: baseURL + "/api/graphql") else { return [] }
        let body: Data
        do {
            body = try JSONSerialization.data(withJSONObject: [
                "query": Self.stageStatusQuery,
                "variables": [
                    "fullPath": fullPath,
                    "id": "gid://gitlab/Ci::Pipeline/\(pipelineID)"
                ]
            ])
        } catch {
            return []
        }

        do {
            let response: StageStatusResponse = try await fetch(
                url,
                baseURL: baseURL,
                token: token,
                method: "POST",
                body: body
            ).value
            let nodes = response.data?.project?.pipeline?.stages?.nodes ?? []
            return nodes.compactMap { node in
                guard let name = node.name, !name.isEmpty else { return nil }
                return ReportedStage(name: name, status: PipelineStageStatus.fromGitLabStatus(node.status))
            }
        } catch {
            return []
        }
    }

    private func fetchApprovals(
        baseURL: String,
        projectID: Int,
        iid: Int,
        token: String
    ) async throws -> ApprovalSummary {
        let url = try apiURL(
            baseURL,
            path: "/api/v4/projects/\(projectID)/merge_requests/\(iid)/approvals"
        )
        do {
            let response: APIApprovals = try await get(url, baseURL: baseURL, token: token)
            let names = (response.approved_by ?? []).compactMap { wrapper -> String? in
                wrapper.user?.name ?? wrapper.user?.username
            }
            return ApprovalSummary(
                approvedBy: names,
                approvalsRequired: response.approvals_required,
                approvalsLeft: response.approvals_left,
                userHasApproved: response.user_has_approved ?? false
            )
        } catch {
            // Approvals API may be unavailable on some Free/CE setups.
            return ApprovalSummary(
                approvedBy: [],
                approvalsRequired: nil,
                approvalsLeft: nil,
                userHasApproved: false
            )
        }
    }

    private static let gitLabDateFormatters: [ISO8601DateFormatter] = {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return [fractional, plain]
    }()

    /// GitLab sends timestamps as ISO-8601, with or without fractional seconds.
    private static func parseGitLabDate(_ value: String?) -> Date {
        guard let value else { return .distantPast }
        for formatter in gitLabDateFormatters {
            if let date = formatter.date(from: value) {
                return date
            }
        }
        return .distantPast
    }

    private func apiURL(_ baseURL: String, path: String) throws -> URL {
        guard let url = URL(string: baseURL + path) else {
            throw GitLabAPIError.invalidURL
        }
        return url
    }

    /// Keeps a GitLab `web_url` only when it points at the configured instance.
    private func sameHostURL(_ string: String?, baseURL: String) -> URL? {
        guard let string, let url = URL(string: string) else { return nil }
        guard let allowed = URL(string: baseURL)?.host,
              let host = url.host,
              host.caseInsensitiveCompare(allowed) == .orderedSame,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }

    private func get<T: Decodable>(_ url: URL, baseURL: String, token: String) async throws -> T {
        try await fetch(url, baseURL: baseURL, token: token).value
    }

    private func fetch<T: Decodable>(
        _ url: URL,
        baseURL: String,
        token: String,
        method: String = "GET",
        body: Data? = nil
    ) async throws -> (value: T, nextPage: Int?) {
        guard let allowedHost = URL(string: baseURL)?.host,
              let host = url.host,
              host.caseInsensitiveCompare(allowedHost) == .orderedSame else {
            throw GitLabAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        request.timeoutInterval = 30

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GitLabAPIError.httpStatus(-1, nil)
        }
        guard let responseHost = http.url?.host,
              responseHost.caseInsensitiveCompare(allowedHost) == .orderedSame else {
            throw GitLabAPIError.invalidURL
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8)
            throw GitLabAPIError.httpStatus(http.statusCode, body?.prefix(200).description)
        }
        let nextPage = http.value(forHTTPHeaderField: "X-Next-Page").flatMap(Int.init).flatMap { page in
            page > 0 ? page : nil
        }
        do {
            let value = try JSONDecoder().decode(T.self, from: data)
            return (value, nextPage)
        } catch {
            throw GitLabAPIError.decoding(error)
        }
    }
}

/// Refuses redirects that leave the GitLab host the request was sent to.
/// Returning nil makes URLSession deliver the redirect response instead of following it,
/// so the bearer token is not sent to any other host.
private final class GitLabSameHostRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let originalHost = task.originalRequest?.url?.host
        let nextHost = request.url?.host
        guard let originalHost, let nextHost,
              originalHost.caseInsensitiveCompare(nextHost) == .orderedSame else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
