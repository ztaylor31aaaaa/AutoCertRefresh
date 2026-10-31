#!/bin/bash
# create_repo.sh - Initialize git repo and push to GitHub for AutoCertRefresh
# Run this ONCE from the AutoCertRefresh directory on your local machine (macOS/Linux/WSL)

set -euo pipefail

# ==== CONFIGURATION - EDIT THESE ====
GITHUB_USER="your-github-username"        # <-- CHANGE THIS
REPO_NAME="AutoCertRefresh"               # <-- Or keep this
VISIBILITY="public"                       # "public" or "private"
# =====================================

echo "🔧 Initializing AutoCertRefresh repository..."

# Check we're in the right place
if [ ! -f "Makefile" ] || [ ! -f "control" ]; then
    echo "❌ Run this from the AutoCertRefresh project root (where Makefile is)"
    exit 1
fi

# Initialize git if needed
if [ ! -d ".git" ]; then
    git init
    echo "✅ Git initialized"
else
    echo "ℹ️  Git already initialized"
fi

# Create .gitignore if missing
if [ ! -f ".gitignore" ]; then
    cat > .gitignore << 'EOF'
.theos/
*.deb
*.dylib
*.so
*.framework
*.o
*.obj
.vscode/
.idea/
*.swp
*.swo
*~
.DS_Store
Thumbs.db
*.log
.debbuilder/
packages/
EOF
    echo "✅ .gitignore created"
fi

# Add all files
git add .

# Initial commit
if git diff --cached --quiet; then
    echo "ℹ️  No changes to commit"
else
    git commit -m "Initial commit: AutoCertRefresh v1.0.0

- Tweak for auto-refreshing certificate-signed apps
- Dopamine account auto-detection
- Keychain-secured verification token
- BGTaskScheduler + launchd fallback
- Preference bundle with test controls
- Native Sileo depiction"
    echo "✅ Initial commit created"
fi

# Set main branch
git branch -M main

# Check if remote exists
if git remote get-url origin >/dev/null 2>&1; then
    echo "ℹ️  Remote 'origin' already exists"
    git remote -v
else
    # Create repo on GitHub (requires gh CLI authenticated)
    if command -v gh >/dev/null 2>&1; then
        echo "📦 Creating GitHub repository..."
        gh repo create "${GITHUB_USER}/${REPO_NAME}" \
            --${VISIBILITY} \
            --description "Auto-refresh certificate-signed apps on jailbroken iOS. Detects Dopamine account, Keychain token, BGTaskScheduler + launchd." \
            --homepage "https://github.com/${GITHUB_USER}/${REPO_NAME}" \
            --disable-wiki \
            --disable-issues=false

        git remote add origin "https://github.com/${GITHUB_USER}/${REPO_NAME}.git"
        echo "✅ GitHub repo created and remote added"
    else
        echo "⚠️  GitHub CLI (gh) not found. Create repo manually at github.com/new"
        echo "   Then run: git remote add origin https://github.com/${GITHUB_USER}/${REPO_NAME}.git"
        read -p "Press Enter after creating the remote repo..."
    fi
fi

# Push
echo "🚀 Pushing to GitHub..."
git push -u origin main

echo ""
echo "✅ Done! Repository pushed to: https://github.com/${GITHUB_USER}/${REPO_NAME}"
echo ""
echo "📋 Next steps:"
echo "   1. Go to: https://github.com/${GITHUB_USER}/${REPO_NAME}/actions"
echo "   2. Watch the 'Build AutoCertRefresh' workflow run"
echo "   3. Download .deb from Artifacts, or create a tag for Release:"
echo "      git tag v1.0.0 && git push origin v1.0.0"
echo ""
echo "🎉 First release will appear at: https://github.com/${GITHUB_USER}/${REPO_NAME}/releases"