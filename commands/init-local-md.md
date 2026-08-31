---
name: init-local-md
description: Create or reinitialize .claude/local.md with environment-specific configuration. Detects project type, environment, and available tools, then writes an appropriate template. Pass `--force` to overwrite without backup prompt.
argument-hint: "[--force]"
---

# Initialize .claude/local.md

Create or reinitialize the .claude/local.md file with environment-specific configuration. This command detects the current environment and creates an appropriate local.md file.

## Pre-Checks

1. **Check if local.md exists**:
```bash
if [ -f ".claude/local.md" ]; then
    echo "⚠️  .claude/local.md already exists!"
    echo "Create backup as .claude/local.md.backup? (y/n)"
    # If yes: cp .claude/local.md .claude/local.md.backup
fi
```

2. **Ensure .claude directory exists**:
```bash
mkdir -p .claude
```

3. **Verify gitignore**:
```bash
# Check if .claude/local.md is gitignored
if ! grep -q "^\.claude/local\.md$" .gitignore 2>/dev/null; then
    echo "Adding .claude/local.md to .gitignore..."
    echo ".claude/local.md" >> .gitignore
fi
```

## Environment Detection

Analyze the project to determine the tech stack and environment:

### 1. Detect Project Type
```bash
# Check for common project files
- package.json → Node.js/JavaScript
- requirements.txt/Pipfile → Python
- Gemfile → Ruby
- go.mod → Go
- Cargo.toml → Rust
- pom.xml/build.gradle → Java
- composer.json → PHP
```

### 2. Detect Environment
```bash
# Check environment indicators
- /.dockerenv → Docker container
- /proc/1/cgroup containing "docker" → Docker
- AWS_EXECUTION_ENV → AWS Lambda
- KUBERNETES_SERVICE_HOST → Kubernetes
- VERCEL → Vercel deployment
- NETLIFY → Netlify deployment
- IS_LOCAL not set → Likely production
```

### 3. Detect Available Tools
```bash
# Check installed tools
- docker --version
- node --version
- python --version
- Database clients (psql, mysql, mongosh)
- Redis cli
- Git configuration
```

## Generate local.md Content

Based on detection, create appropriate content:

### For Local Development Environment:
```markdown
# Local Development Environment

## System Information
- OS: [detected OS - macOS/Linux/Windows]
- Shell: [detected shell - bash/zsh/fish]
- Working Directory: [current directory]

## Detected Project Type
- Primary Language: [detected from files]
- Framework: [if detected]
- Package Manager: [npm/yarn/pip/etc]

## Environment Setup
```bash
# [Project-specific setup based on detected type]
# Example for Node.js:
nvm use 18
npm install

# Example for Python:
python -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

## Local Services
# [Check for running services]
- Database: [if detected via port scan or config]
- Cache: [Redis/Memcached if detected]
- Message Queue: [if detected]

## Available Tools
- Git: [version]
- Docker: [version or "not installed"]
- [Other detected tools]

## Development Commands
```bash
# [Inferred from package.json scripts or Makefile]
# Start development server
npm run dev

# Run tests
npm test

# Build project
npm run build
```

## Performance Optimizations
- Node.js memory: `export NODE_OPTIONS='--max-old-space-size=4096'`
- [Other language-specific optimizations]

## Debugging Configuration
- Node.js: `export DEBUG='app:*'`
- [Framework-specific debug settings]

## Local Endpoints
- Application: http://localhost:[detected port or 3000]
- API Documentation: http://localhost:[port]/docs
- Database UI: http://localhost:[port]

## Environment Variables
```bash
# Create .env.local with:
DATABASE_URL=postgresql://localhost:5432/[project]_dev
REDIS_URL=redis://localhost:6379
API_KEY=local-development-key
```

## Common Issues & Solutions
- Port already in use: `lsof -ti:[PORT] | xargs kill -9`
- Clear node_modules: `rm -rf node_modules package-lock.json && npm install`
- [Project-specific common issues]

## Git Workflow
- Feature branches: `git checkout -b feature/[ticket]-[description]`
- Pre-commit hooks: [if detected in .git/hooks]

## Notes
- This file is gitignored and specific to your local environment
- Update this file as you discover environment-specific optimizations
- Last updated: [current date]
```

### For Production/Deployment Environment:
```markdown
# Production Environment

## Environment Information
- Type: [Production/Staging/CI]
- Platform: [AWS/GCP/Azure/VPS/Docker]
- Region: [if applicable]

## System Configuration
- OS: [detected OS]
- CPU: [core count]
- Memory: [available RAM]
- Disk: [available space]

## Service Configuration
- Application Server: [process manager/container orchestrator]
- Web Server: [nginx/apache if detected]
- Database: [connection string format, no credentials]
- Cache: [Redis/Memcached endpoint format]

## Deployment Configuration
```bash
# Deployment commands detected
[if Dockerfile exists]: docker build & run commands
[if PM2]: pm2 start ecosystem.config.js
[if systemd]: systemctl commands
```

## Monitoring & Logs
- Application logs: [log location]
- System logs: /var/log/[service]
- Monitoring: [if APM detected]

## Performance Settings
- Process count: [CPU cores or configured value]
- Memory limits: [if configured]
- Connection pools: [database/redis settings]

## Health Checks
- Endpoint: [/health or detected endpoint]
- Expected response: 200 OK
- Dependencies checked: [database, cache, external services]

## Troubleshooting Commands
```bash
# Check application status
[appropriate command for the platform]

# View recent logs
[tail command for log location]

# Check resource usage
htop or top
df -h
free -m
```

## Security Notes
- Secrets managed via: [environment variables/secret manager]
- SSL/TLS: [enabled/certificate location]
- Firewall rules: [basic description if detected]

## Maintenance Procedures
- Restart app: [command]
- Clear cache: [command]
- Database backup: [basic command structure]

## Important Reminders
- This file is gitignored and environment-specific
- Never commit actual credentials or secrets
- Last generated: [current date]
```

## Template Selection Logic

Choose template based on environment indicators:

```python
if is_ci_environment():
    # Minimal CI-focused template
elif is_container():
    # Container-specific template
elif is_cloud_platform():
    # Cloud platform template (AWS/GCP/Azure)
elif has_dev_dependencies():
    # Local development template
else:
    # Generic production template
```

## Post-Creation Actions

1. **Verify file created**:
```bash
if [ -f ".claude/local.md" ]; then
    echo "✅ Successfully created .claude/local.md"
    echo "📝 Please review and customize the generated content"
fi
```

2. **Check gitignore again**:
```bash
git check-ignore .claude/local.md
if [ $? -eq 0 ]; then
    echo "✅ Confirmed: .claude/local.md is gitignored"
else
    echo "⚠️  WARNING: .claude/local.md is NOT gitignored!"
fi
```

3. **Suggest next steps**:
```markdown
Next steps:
1. Review the generated .claude/local.md
2. Add any missing environment-specific details
3. Update with your personal debugging preferences
4. Add local service URLs and ports
5. Include any machine-specific optimizations
```

## Error Handling

### If detection fails:
Create a generic template with placeholders:

```markdown
# Local Environment Configuration

## ⚠️ Auto-detection failed - Please customize this file

## System Information
- OS: [YOUR_OS]
- Project Type: [YOUR_PROJECT_TYPE]
- Environment: [development/production]

## Setup Instructions
```bash
# Add your setup commands here
```

## Local Services
- Database: [URL/connection string]
- Cache: [URL]
- Other: [service URLs]

## Development Commands
- Start: [command]
- Test: [command]
- Build: [command]

## Notes
- This file is gitignored
- Add environment-specific configurations here
- Last updated: [current date]
```

## Usage Examples

### Basic usage:
```bash
# Run the init command
/init-local-md
```

### With backup:
```bash
# If local.md exists, it will prompt to backup
/init-local-md
# > Create backup? (y/n): y
# > Created .claude/local.md.backup
```

### Force recreation:
```bash
# Add --force flag handling
/init-local-md --force
```

Remember: This file should contain environment-specific information that helps Claude understand your local setup but should NEVER contain sensitive credentials or secrets that shouldn't be on your local machine.
