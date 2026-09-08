#!/usr/bin/env bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root/windows"
dotnet restore VisionStack.Windows.Tests/VisionStack.Windows.Tests.csproj --locked-mode
dotnet test VisionStack.Windows.Tests/VisionStack.Windows.Tests.csproj --configuration Release --no-restore
