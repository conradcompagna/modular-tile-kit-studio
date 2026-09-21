# Security

Report a suspected vulnerability through the repository's GitHub Security tab using
private vulnerability reporting if available; otherwise contact the owner through a
private contact they publish on their GitHub profile. Do not put credentials, private
documents or exploit payloads targeting a live service in a public issue. This
repository does not currently declare a support window or response-time commitment.

Include the affected commit, a minimal local reproduction, expected/actual behavior
and impact. Use synthetic documents and local accounts. Run untrusted content only
in an isolated fixture environment. Dependency updates and source fixes require
independent review and deployment before they protect a running service.

Optional editor automation and ComfyUI integrations should remain local or be placed
behind an explicitly configured trusted boundary; do not expose them to the Internet.
The regression runner disables the normal plugin in a disposable project.
