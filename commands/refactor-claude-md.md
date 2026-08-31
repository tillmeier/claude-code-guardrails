---
name: refactor-claude-md
description: Refactor a project's Claude documentation to the distributed pattern — lean CLAUDE.md core + on-demand tiers (.claude/docs/ feature details, .claude/rules/ path-scoped conventions, nested per-subsystem CLAUDE.md, .claude/local.md environment), with an auto-generated doc index and no @-imports. Detects misplaced content and reorganizes; backs up before changes.
---

# Refactor CLAUDE.md Documentation System

Analyze and refactor the project's Claude documentation system following the distributed documentation pattern and community best practices. This includes CLAUDE.md (main), .claude/local.md (environment-specific), and .claude/docs/ (detailed features).

## Pre-Analysis Phase

1. **Audit existing documentation structure**:
   - Check for existing CLAUDE.md, .claude/local.md, and .claude/docs/ files
   - Note any CLAUDE.local.md files (deprecated naming)
   - Identify misplaced content that should be redistributed

2. **Analyze project characteristics**:
   - Project type, tech stack, and architecture
   - Development workflow and tooling
   - Team size and collaboration patterns
   - Deployment environments (local dev, staging, production)

3. **Check for existing patterns**:
   - Custom slash commands in .claude/commands/
   - MCP server configurations
   - Team-specific conventions or terminology

## Refactoring Phase

### 1. Main CLAUDE.md Structure

Create/update CLAUDE.md with this optimized structure:

```markdown
# Project: [PROJECT_NAME]

## 🎯 Project Overview
[1-2 line description of what this project does]

## 📁 Documentation
**Environment-specific (read first):** .claude/local.md   # do NOT @-import it (see note below)
**Full doc index:** .claude/docs/README.md                # prefer auto-generated (see Step below)
**Path-scoped rules:** .claude/rules/                     # load when Claude READS a matching file
**Subsystem guidance:** nested CLAUDE.md in hot subdirs   # load only when working there

### Hot cross-cutting docs (only the ones most sessions touch):
- [feature].md - [5-10 word description]
- [module].md - [5-10 word description]

**Important**: Read the relevant doc from .claude/docs/ BEFORE working on a feature.

## 🏗️ Architectural decisions Claude can NOT derive
<!-- Do NOT write an architecture overview, directory layout or dependency list here: all derivable
     from the code, and /doctor's trim strips exactly those. Only decisions whose *rationale* is
     invisible in the code — "X is intentional because Y", "never use Z here, it broke W". -->
- [Non-obvious decision] — because [reason that isn't visible in the code]
- Full picture: .claude/docs/[architecture].md

## 🛠️ Essential Commands
### Development
- `[build]` - Build the project
- `[test]` - Run tests
- `[lint]` - Check code style
- `[dev]` - Start development server

### Git Workflow
- Branch naming: feature/[task-id]-[brief-description]
- Commit style: [conventional commits/other]
- Always run tests before pushing

## 📋 Core Conventions
### Code Style
- [Language] version: [X.Y]
- [Key formatting rule]
- [Import convention]

### Project-Specific Patterns
- [Domain term]: [definition]
- [Custom pattern]: [when to use]

## 🚀 Environment quirks
<!-- Not a Quick Start — clone/install/run belongs in the README and is derivable. Keep only what
     bites Claude: required env vars, a service that must be up, a step that fails silently. -->
- [Required var / running service / silent-failure step]

## ⚡ Claude Code Instructions
- Run tests before committing
- Update relevant docs in .claude/docs/ when adding features
- Ask for clarification on ambiguous requirements
- For detailed implementation patterns, check .claude/docs/
```

### 2. Environment-Specific .claude/local.md

Create/update .claude/local.md for environment-specific details:

**⚠️ IMPORTANT: This file MUST be gitignored as it contains environment-specific configurations**

```markdown
# Local Development Environment

## System Requirements
- Node.js: v[X.Y.Z]
- Python: [version] with pyenv
- Docker: [if applicable]

## Environment Setup
```bash
# Specific setup commands
export API_KEY="local-dev-key"
pyenv local 3.11.5
```

## Local Services
- Database: PostgreSQL on port 5432
- Redis: localhost:6379
- [Other services]

## Performance Optimizations
- Disable React DevTools: `window.__REACT_DEVTOOLS_GLOBAL_HOOK__.isDisabled = true`
- Use local caching: [specific strategy]

## Debugging Tips
- [Tool-specific debug command]
- [Local-only debug endpoint]

## Local vs Production Differences
- Authentication: Mock auth in local
- API endpoints: http://localhost:3000 vs https://api.production.com
- Feature flags: All enabled locally
```

### 3. Feature Documentation in .claude/docs/

Organize detailed documentation by feature/module:

```markdown
# [Feature Name]

## Overview
[1-2 line description]

## Key Components
- `src/[path]/[component]` - [purpose]
- `src/[path]/[service]` - [purpose]

## Implementation Patterns
```typescript
// Specific code pattern example
```

## Testing Strategy
- Unit tests: [approach]
- Integration tests: [approach]

## Common Issues & Solutions
- [Issue]: [Solution]

## Related Documentation
- See [other-feature].md for [relationship]
```

## Distribution Guidelines

### What goes where:

**CLAUDE.md (Always relevant - COMMITTED TO GIT)**:
- One line on what the project is
- Architectural decisions whose *rationale* isn't visible in the code (not an architecture overview —
  that's derivable, and `/doctor`'s trim strips it)
- Bash commands Claude can't guess; the test runner and how to run a single test
- Conventions that differ from language/tool defaults; repo etiquette (branch naming, PR style)
- Environment quirks that bite (required vars, a service that must be running)
- A one-line pointer to .claude/local.md (read on demand — NOT an @-import)
- Pointers to the on-demand tiers: .claude/docs/ index, .claude/rules/, nested CLAUDE.md
- NOT: directory layouts, dependency lists, file-by-file descriptions, quick-start/install steps,
  API docs, tutorials, or anything Claude works out by reading the code

**local.md (Environment-specific - MUST BE GITIGNORED)**:
- System requirements
- Local setup instructions
- Environment variables
- Local service configurations
- Debugging tools and tips
- Performance optimizations
- Differences between environments
- Personal API keys or secrets
- Machine-specific paths

**.claude/docs/ (Feature-specific - COMMITTED TO GIT, loads on read)**:
- Detailed implementation guides
- Module-specific patterns
- Complex business logic explanation
- API documentation
- Database schemas
- Integration guides

**.claude/rules/ (Path-scoped conventions - COMMITTED, loads when Claude READS a matching file)**:
- A rule file is markdown with YAML frontmatter: `paths: ["src/**/*.py", "app.py"]`
- Hard invariants that apply to a *file class* (logging convention, auth pattern, DB/ORM gotchas,
  endpoint conventions, `.env` policy) — load only on a matching read = 0 always-on cost by design
- This is the cheapest mechanism and the most under-used. Move path-specific "always do X" prose
  OUT of CLAUDE.md into here.
- Keep them few and short, never `@`-import from inside one, and don't park deep reference docs in a
  `.claude/rules/**/refs/` subfolder: every `.md` under `rules/` is discovered recursively, and
  path-scoping has been reported leaking into always-on context
  ([#16299](https://github.com/anthropics/claude-code/issues/16299)). Verify with `/context`.

**Nested CLAUDE.md (per-subsystem - COMMITTED, loads when working in that dir)**:
- For a large single tree, a root CLAUDE.md either bloats with every subsystem's rules or stays too
  generic. Add a `CLAUDE.md` to each hot subdirectory (`src/services/x/CLAUDE.md`) with that area's
  pointers + local invariants. It loads only when Claude reads files there. (Anthropic-recommended
  for large codebases.) Root CLAUDE.md keeps only cross-cutting content + a pointer to these.

## Implementation Steps

1. **Backup existing files**: 
   ```bash
   cp CLAUDE.md CLAUDE.md.backup
   cp -r .claude .claude.backup
   ```

2. **Create directory structure**:
   ```bash
   mkdir -p .claude/docs
   ```

3. **Set up .gitignore**:
   ```bash
   # Add to .gitignore
   echo ".claude/local.md" >> .gitignore
   ```
   **Critical**: .claude/local.md MUST be gitignored as it contains environment-specific configurations

4. **Redistribute content**:
   - Move environment-specific content from CLAUDE.md to .claude/local.md
   - Extract detailed feature documentation to .claude/docs/[feature].md
   - Keep only essential, always-relevant info in CLAUDE.md

5. **Point to local.md — do NOT `@`-import it**:
   - `@`-imports load at launch and do NOT reduce context; importing `local.md` into every session
     re-introduces the always-on bloat you're trying to remove.
   - Instead, add a one-line pointer (`Environment-specific (read first): .claude/local.md`) and let
     Claude read it on demand. Same for the doc index — prefer auto-generated over a hand-maintained list.

6. **Update references**:
   - Replace any @ imports with descriptive text in documentation index
   - Ensure no circular dependencies

7. **Create local.md template** (optional):
   ```bash
   # Create a template for team members
   cp .claude/local.md .claude/local.md.template
   # Add note at top of template
   echo "# Copy this to local.md and customize for your environment" > .claude/local.md.template
   ```

8. **Validate structure**:
   - Confirm all essential commands work
   - Check that documentation is findable
   - Verify no duplicate information

9. **Commit changes**:
   ```bash
   git add CLAUDE.md .claude/docs/ .claude/local.md.template .gitignore
   # Note: .claude/local.md is NOT added as it's gitignored
   git commit -m "refactor: Reorganize Claude documentation with distributed pattern
   
   - Split environment-specific content to .claude/local.md (gitignored, read on demand)
   - Moved detailed docs to .claude/docs/; path-scoped conventions to .claude/rules/
   - Slimmed CLAUDE.md to cross-cutting content + pointers (no @-imports)
   - Created local.md.template for team setup
   - Improved documentation discoverability"
   ```

## Best Practices Applied

1. **Context Efficiency**: Keep CLAUDE.md concise (~200 lines max). But budget the *whole* always-on
   tier, not one file: CLAUDE.md + the user-global `~/.claude/CLAUDE.md` + any auto-memory index all
   load every session and compete for the model's ~150-200 reliable-instruction ceiling. Measure the
   sum (`wc -c` ÷ 4 ≈ tokens); push everything situational to on-demand tiers (docs/rules/nested/skills)
2. **Living Documentation**: Use # in Claude Code to add learnings on the fly
3. **Clear Hierarchy**: Use consistent heading levels and formatting
4. **Actionable Content**: Focus on commands and patterns, not theory
5. **Cross-References**: Link between related docs without @ imports
6. **Version Control**: 
   - **ALWAYS gitignore .claude/local.md** (environment-specific)
   - Commit CLAUDE.md and .claude/docs/ (shared documentation)
   - Optionally commit .claude/local.md.template as a starting point

## Follow-up Actions

1. **Create missing slash commands** referenced in documentation
2. **Set up MCP servers** if beneficial for the project
3. **Document team-specific workflows** in .claude/docs/workflows.md
4. **Add code examples** to .claude/docs/ for complex patterns
5. **Create templates** in .claude/docs/templates/ for common tasks

Remember: The goal is to make Claude Code understand your project deeply while maintaining clear separation between always-relevant info (CLAUDE.md), environment-specific details (local.md), and detailed feature documentation (docs/).
