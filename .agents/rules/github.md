# GitHub Rules

## PR Comments & Code Reviews

- **NEVER** include "Generated with Claude Code" or similar attribution in PR comments, code review comments, or issue comments
- Keep comments concise and professional
- Use markdown formatting for clarity

## Pull Requests

- **MANDATORY**: Always use the `/create-pr` skill when creating pull requests
- **NEVER** create PRs manually with `gh pr create` - the skill ensures the correct template is used
- Keep PR titles under 70 characters
- Use conventional commit format for PR titles

## Releases

- Pull requests target `main`. Every merge deploys to staging, then tags the next version and deploys
  it to production (`.github/workflows/backend.yml`)
- The PR title sets the version bump: `type(scope)!:` major, `feat` minor, any other type patch
- Squash-merge, so the release reads the PR title; a push without a PR falls back to the commit subject
- Never tag by hand to release; push a `v*` tag only to redeploy or roll back to a version
