import Foundation

extension CodexTextProvider {
    public static func requestArguments(schema: URL, response: URL, instructions: String, selection: CodexModel, effort: ReasoningEffort = .medium) throws -> [String] {
        let encodedInstructions = String(decoding: try JSONEncoder().encode(instructions), as: UTF8.self)
        let overrides = [
            "model_provider=\"openai\"", "approval_policy=\"never\"",
            "model_reasoning_effort=\"\(effort.rawValue)\"",
            "developer_instructions=\(encodedInstructions)", "project_doc_max_bytes=0",
            "web_search=\"disabled\"", "mcp_servers={}",
            "tools.update_plan.enabled=false", "tools.experimental_request_user_input.enabled=false",
            "skills.include_instructions=false", "skills.bundled.enabled=false",
            "features.skip_host_skill_discovery=true", "features.code_mode=false",
            "features.hooks=false", "features.plugins=false", "features.apps=false",
            "features.shell_tool=false", "features.unified_exec=false", "features.multi_agent=false",
            "features.multi_agent_v2=false", "features.view_image=false", "features.image_generation=false",
            "features.in_app_browser=false", "features.skill_search=false", "features.memories=false"
        ]
        return ["exec", "--json", "--model", selection.rawValue, "--ignore-user-config", "--ignore-rules", "--ephemeral", "--sandbox", "read-only",
                "--skip-git-repo-check", "--color", "never", "--output-schema", schema.path,
                "--output-last-message", response.path]
            + overrides.flatMap { ["-c", $0] } + ["-"]
    }

}
