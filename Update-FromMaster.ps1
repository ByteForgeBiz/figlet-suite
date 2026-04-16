[CmdletBinding()]
param(
    [ValidateSet('merge', 'rebase')]
    [string]$Mode = 'rebase',

    [switch]$KeepTempFile
)

$ErrorActionPreference = 'Stop'

function Assert-GitSuccess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if ($LASTEXITCODE -ne 0) {
        throw $Message
    }
}

function Test-GitStateFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    return Test-Path (Join-Path $gitDir $Name)
}

function Get-StatusPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StatusLine
    )

    if ($StatusLine.Length -lt 4) {
        return $null
    }

    $pathPortion = $StatusLine.Substring(3)
    $renameParts = $pathPortion -split ' -> ', 2
    return $renameParts[-1].Trim()
}

function Test-IgnoredDotFolderStatus {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StatusLine
    )

    if (-not $StatusLine.StartsWith('!! ')) {
        return $false
    }

    $path = Get-StatusPath $StatusLine
    if ([string]::IsNullOrWhiteSpace($path)) {
        return $false
    }

    $normalizedPath = $path.Replace('\', '/')
    return $normalizedPath -match '^\.[^/]+/'
}

function Get-IgnoredDotFolder {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StatusLine
    )

    if (-not (Test-IgnoredDotFolderStatus $StatusLine)) {
        return $null
    }

    $path = Get-StatusPath $StatusLine
    if ([string]::IsNullOrWhiteSpace($path)) {
        return $null
    }

    $normalizedPath = $path.Replace('\', '/')
    $pathParts = $normalizedPath -split '/', 2

    if ($pathParts.Count -eq 0 -or [string]::IsNullOrWhiteSpace($pathParts[0])) {
        return $null
    }

    return $pathParts[0]
}

function Get-TrimmedGitOutput {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $output = git -C $repoRoot @Arguments
    Assert-GitSuccess "Git command failed: git -C `"$repoRoot`" $($Arguments -join ' ')"

    if ($null -eq $output) {
        return ''
    }

    return ([string]$output).Trim()
}

function Test-BuildArtifactStatus {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StatusLine
    )

    if (-not ($StatusLine.StartsWith('?? ') -or $StatusLine.StartsWith('!! '))) {
        return $false
    }

    $path = Get-StatusPath $StatusLine
    if ([string]::IsNullOrWhiteSpace($path)) {
        return $false
    }

    $normalizedPath = $path.Replace('\', '/')
    return $normalizedPath -match '(^|/)(bin|obj)(/|$)'
}

function Get-BuildArtifactDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StatusLine
    )

    if (-not (Test-BuildArtifactStatus $StatusLine)) {
        return $null
    }

    $path = Get-StatusPath $StatusLine
    if ([string]::IsNullOrWhiteSpace($path)) {
        return $null
    }

    $normalizedPath = $path.Replace('\', '/')
    $match = [regex]::Match($normalizedPath, '^(.*?)(?:^|/)(bin|obj)(?:/.*)?$')
    if (-not $match.Success) {
        return $null
    }

    $prefix = $match.Groups[1].Value.TrimEnd('/')
    $folderName = $match.Groups[2].Value
    if ([string]::IsNullOrWhiteSpace($prefix)) {
        return $folderName
    }

    return "$prefix/$folderName"
}

$repoRoot = (Resolve-Path $PSScriptRoot).Path
$tempBat = $null
$stashCreated = $false
$stashRef = $null
$stashName = $null
$exitCode = 0

git -C $repoRoot rev-parse --show-toplevel | Out-Null
Assert-GitSuccess "This script must be run from inside a git repository."

$currentBranch = Get-TrimmedGitOutput @('branch', '--show-current')

if ([string]::IsNullOrWhiteSpace($currentBranch)) {
    throw "Detached HEAD is not supported. Check out a branch first."
}

if ($currentBranch -eq 'master') {
    throw "You are already on 'master'. Switch to a feature branch before running this script."
}

$gitDir = (git -C $repoRoot rev-parse --git-dir).Trim()
Assert-GitSuccess "Unable to locate the .git directory."

if (-not [System.IO.Path]::IsPathRooted($gitDir)) {
    $gitDir = Join-Path $repoRoot $gitDir
}

$stateFiles = @(
    'MERGE_HEAD',
    'CHERRY_PICK_HEAD',
    'REVERT_HEAD',
    'BISECT_LOG',
    'rebase-apply',
    'rebase-merge'
)

foreach ($stateFile in $stateFiles) {
    if (Test-GitStateFile $stateFile) {
        throw "Repository has an in-progress git operation ('$stateFile'). Finish or abort it before running this script."
    }
}

$statusOutput = @(git -C $repoRoot status --porcelain=v1 --untracked-files=all --ignored=matching)
Assert-GitSuccess "Unable to inspect the worktree state."

$buildArtifactDirectories = @(
    $statusOutput |
        ForEach-Object { Get-BuildArtifactDirectory $_ } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Sort-Object -Unique
)

foreach ($buildArtifactDirectory in $buildArtifactDirectories) {
    $candidateBuildArtifactPath = Join-Path $repoRoot ($buildArtifactDirectory.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
    $fullBuildArtifactPath = [System.IO.Path]::GetFullPath($candidateBuildArtifactPath)
    $repoRootWithSeparator = $repoRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar

    if (-not $fullBuildArtifactPath.StartsWith($repoRootWithSeparator, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove build artifacts outside the repository root: $buildArtifactDirectory"
    }

    if (Test-Path -LiteralPath $fullBuildArtifactPath -PathType Container) {
        Remove-Item -LiteralPath $fullBuildArtifactPath -Recurse -Force
        Write-Host "Removed generated build artifacts: $buildArtifactDirectory"
    }
}

if ($buildArtifactDirectories.Count -gt 0) {
    $statusOutput = @(git -C $repoRoot status --porcelain=v1 --untracked-files=all --ignored=matching)
    Assert-GitSuccess "Unable to inspect the worktree state after cleaning build artifacts."
}

$stashRelevantStatus = @($statusOutput | Where-Object { -not (Test-IgnoredDotFolderStatus $_) })

if ($stashRelevantStatus.Count -gt 0) {
    $stashName = "{0} {1}" -f $Mode, (Get-Date -Format 'yyyy-MM-dd HH:mm')
    $ignoredDotFolders = @(
        $statusOutput |
            ForEach-Object { Get-IgnoredDotFolder $_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique
    )

    $stashArguments = @('stash', 'push', '--all', '--message', $stashName, '--', '.')
    foreach ($ignoredDotFolder in $ignoredDotFolders) {
        $stashArguments += ":(top,glob,exclude)$ignoredDotFolder/**"
    }

    git -C $repoRoot @stashArguments | Out-Null
    Assert-GitSuccess "Unable to stash local changes before switching branches."

    $stashRef = (git -C $repoRoot stash list -1 --format="%gd").Trim()
    Assert-GitSuccess "Unable to inspect the created stash."

    if ([string]::IsNullOrWhiteSpace($stashRef)) {
        throw "A stash was created, but the script could not identify it for restoration."
    }

    $stashCreated = $true
}

$tempBat = Join-Path ([System.IO.Path]::GetTempPath()) ("update-from-master-{0}.bat" -f ([guid]::NewGuid().ToString('N')))
$repoRootEscaped = $repoRoot.Replace('%', '%%').Replace('"', '""')
$currentBranchEscaped = $currentBranch.Replace('"', '""')

$batchContent = @"
@echo off
setlocal

set "REPO_ROOT=$repoRootEscaped"
set "ORIGINAL_BRANCH=$currentBranchEscaped"
set "MODE=$Mode"

cd /d "%REPO_ROOT%"
if errorlevel 1 exit /b 1

echo.
echo ^> git switch master
git switch master
if errorlevel 1 exit /b 1

echo.
echo ^> git pull --ff-only origin master
git pull --ff-only origin master
if errorlevel 1 exit /b 1

echo.
echo ^> git switch "%ORIGINAL_BRANCH%"
git switch -- "%ORIGINAL_BRANCH%"
if errorlevel 1 exit /b 1

echo.
if /i "%MODE%"=="rebase" (
    echo ^> git rebase master
    git rebase master
) else (
    echo ^> git merge master
    git merge master
)
if errorlevel 1 exit /b 1

echo.
if /i "%MODE%"=="rebase" (
    echo ^> git push --force-with-lease origin "%ORIGINAL_BRANCH%"
    git push --force-with-lease origin "%ORIGINAL_BRANCH%"
) else (
    echo ^> git push origin "%ORIGINAL_BRANCH%"
    git push origin "%ORIGINAL_BRANCH%"
)
if errorlevel 1 exit /b 1

echo.
echo Done.
exit /b 0
"@

Set-Content -LiteralPath $tempBat -Value $batchContent -Encoding Default

Write-Host "Original branch: $currentBranch"
Write-Host "Integration mode: $Mode"
Write-Host "Temporary runner: $tempBat"

if ($stashCreated) {
    Write-Host "Stashed current worktree as: $stashName ($stashRef)"
} else {
    Write-Host "Worktree had no stash-worthy changes outside ignored dot folders. No stash created."
}

try {
    & $tempBat
    $exitCode = $LASTEXITCODE
}
finally {
    $branchAfterRun = ''
    try {
        $branchAfterRun = Get-TrimmedGitOutput @('branch', '--show-current')
    }
    catch {
        Write-Warning "Unable to determine the current branch during cleanup. Continuing with stash restoration and temp-file cleanup."
    }

    if (-not [string]::IsNullOrWhiteSpace($branchAfterRun) -and $branchAfterRun -ne $currentBranch) {
        $hasGitState = $false

        foreach ($stateFile in $stateFiles) {
            if (Test-GitStateFile $stateFile) {
                $hasGitState = $true
                break
            }
        }

        if (-not $hasGitState) {
            git -C $repoRoot switch -- $currentBranch | Out-Null
        }
    }

    if ($stashCreated -and -not [string]::IsNullOrWhiteSpace($stashRef)) {
        git -C $repoRoot stash apply --index $stashRef | Out-Null

        if ($LASTEXITCODE -eq 0) {
            git -C $repoRoot stash drop $stashRef | Out-Null

            if ($LASTEXITCODE -eq 0) {
                Write-Host "Restored stashed worktree from: $stashName"
            } else {
                Write-Warning "The stashed worktree was applied, but dropping '$stashRef' failed."
            }
        } else {
            Write-Warning "Failed to restore stashed worktree from '$stashRef'. The stash was kept."
        }
    }

    if ($KeepTempFile) {
        Write-Host "Temporary batch file kept at: $tempBat"
    } else {
        Remove-Item -LiteralPath $tempBat -ErrorAction SilentlyContinue
        Write-Host "Temporary batch file removed."
    }
}

if ($stashCreated) {
    Write-Host "Summary: stashed dirty worktree as '$stashName', updated from master using '$Mode', and attempted to restore the stash."
} else {
    Write-Host "Summary: no stash-worthy changes outside ignored dot folders were found, updated from master using '$Mode', and no stash was needed."
}

exit $exitCode
