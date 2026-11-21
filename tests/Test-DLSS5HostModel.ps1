# Loaded by the release suite after importing the candidate library.
Invoke-Dlss5Case 'host-model argument parsing and required host' {
    $launch = Resolve-Dlss5LaunchArguments @('--model', 'provider/Custom:Model', '--host', 'codex', 'a custom task')
    Assert-Dlss5Equal $launch.HostValue 'codex' 'Host was lost.'
    Assert-Dlss5Equal $launch.ModelValue 'provider/Custom:Model' 'Model spelling changed.'
    Assert-Dlss5Equal $launch.Mode 'a custom task' 'Task was lost.'
    Assert-Dlss5True $launch.ArgumentPresent 'Task presence was lost.'
    $launch = Resolve-Dlss5LaunchArguments @('--host', 'claude', '--prompt-file', 'task.txt')
    Assert-Dlss5Equal $launch.Mode '--prompt-file' 'Prompt-file mode was lost.'
    Assert-Dlss5Equal $launch.Argument1 'task.txt' 'Prompt-file path was lost.'
    $launch = Resolve-Dlss5LaunchArguments @('--host', 'claude')
    Assert-Dlss5True (-not $launch.ArgumentPresent) 'Host-only launch became an empty task.'
    $launch = Resolve-Dlss5LaunchArguments @()
    Assert-Dlss5True (-not $launch.ArgumentPresent) 'No-argument launch became an empty task.'
    foreach ($tokens in @(
        ,@('--host')
        ,@('--model')
        ,@('--host', '')
        ,@('--model', 'sol')
        ,@('--host', 'codex', '--model')
        ,@('--host', 'codex', '--model', '--host')
        ,@('--host', 'codex', '--host', 'claude')
        ,@('--host', 'codex', '--model', 'sol', '--model', 'opus')
        ,@('--host', 'codex', '--dump-payload', 'out')
        ,@('--host', 'codex', '--internal-session-changes')
        ,@('--host', 'codex', '--model', 'bad&value')
        ,@('--host', 'codex', '--model', ('x' * 129))
    )) {
        Assert-Dlss5Throws { Resolve-Dlss5LaunchArguments $tokens } ([ArgumentException]) "Invalid arguments accepted: $($tokens -join ' ')"
    }
}

Invoke-Dlss5Case 'host-model failure pause recognizes an internal launch that argument parsing refused' {
    # Each launch is refused before the main block learns its mode, so the pause decision reads the raw tokens instead.
    foreach ($tokens in @(
        ,@('--host', 'codex', '--internal-session-changes')
        ,@('--host', 'codex', '--dump-payload', 'out')
        ,@('--host', '--internal-status')
        ,@('--host', '', '--internal-status')
        ,@('--model', 'sol', '--internal-status')
        ,@('--host', 'codex', '--model', 'bad&value', '--internal-status')
        ,@('--model', '--dump-payload', 'out')
        ,@('--host', 'codex', '--host', 'claude', '--internal-execute', 'token')
    )) {
        Assert-Dlss5Throws { Resolve-Dlss5LaunchArguments $tokens } ([ArgumentException]) "The launch was not refused: $($tokens -join ' ')"
        Assert-Dlss5True (Test-Dlss5InternalLaunch $tokens) "A refused internal launch would pause: $($tokens -join ' ')"
    }
    $accepted = @(
        ,@('--internal-status')
        ,@('--dump-payload', 'out')
        foreach ($item in $script:Dlss5PackageItems) { ,@($item, 'token') }
    )
    Assert-Dlss5Equal $accepted.Count ($script:Dlss5PackageItems.Count + 2) 'The accepted internal launches were not each kept whole.'
    foreach ($tokens in $accepted) {
        Assert-Dlss5True (Test-Dlss5InternalLaunch $tokens) "An accepted internal launch would pause: $($tokens -join ' ')"
    }
    foreach ($tokens in @(
        ,@()
        ,@('')
        ,@('--host', 'claude')
        ,@('--host', 'codex', 'a task')
        ,@('--host', '', 'a task')
        ,@('fix --internal-status')
        ,@('--prompt-file', 'task.txt')
        ,@('--host', 'codex', '--model')
        ,@('--model', 'sol', 'a task')
    )) {
        Assert-Dlss5True (-not (Test-Dlss5InternalLaunch $tokens)) "An agent launch would not pause: $($tokens -join ' ')"
    }
    $payload = [IO.File]::ReadAllText([IO.Path]::GetFullPath($UpdaterPath))
    Assert-Dlss5True $payload.Contains('Invoke-Dlss5FailurePause -Code $processExitCode -InternalMode (Test-Dlss5InternalLaunch $script:Dlss5LaunchTokens) -Suppress $suppressFailurePause') 'The main block does not decide the pause from the launch tokens.'
}

Invoke-Dlss5Case 'host-model precedence preserves model text and process handoff' {
    $names = @('DLSS5_AGENT_HOST', 'DLSS5_AGENT', 'DLSS5_CODEX_MODEL', 'DLSS5_CLAUDE_MODEL', 'DLSS5_CODEX_EFFORT', 'DLSS5_CLAUDE_EFFORT')
    $saved = @{}
    foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
    function Resolve-Dlss5AgentCommand {
        param([string]$Value)
        if ($Value -cin @('codex', 'claude')) { return [pscustomobject]@{ Kind = $Value; Command = $Value } }

        return $null
    }
    try {
        $env:DLSS5_AGENT = 'retired-invalid-value'
        $env:DLSS5_AGENT_HOST = 'claude'
        $env:DLSS5_CODEX_MODEL = 'environment-model'
        $env:DLSS5_CLAUDE_MODEL = 'environment-claude'
        $env:DLSS5_CODEX_EFFORT = 'high'
        $env:DLSS5_CLAUDE_EFFORT = 'medium'
        foreach ($model in @('sol', 'gpt-6.1-sol', 'provider/Custom:Model', 'opus[1m]')) {
            $launch = Resolve-Dlss5LaunchArguments @('--host', 'codex', '--model', $model)
            Set-Dlss5LaunchOverrides $launch
            $selected = Select-Dlss5Agent
            Assert-Dlss5Equal $selected.Kind 'codex' 'Host flag did not override the environment.'
            Assert-Dlss5Equal $selected.Model $model 'Model flag was expanded, changed, or ignored.'
            Assert-Dlss5Equal $selected.Effort 'high' 'Host effort configuration was lost.'
            Assert-Dlss5Equal $env:DLSS5_CLAUDE_MODEL 'environment-claude' 'Other host model was changed.'
            # Startup re-execution invokes the wrapper without flags and inherits process environment.
            Set-Dlss5LaunchOverrides (Resolve-Dlss5LaunchArguments @())
            Assert-Dlss5Equal (Select-Dlss5Agent).Model $model 'Flag choice was lost on argument-free handoff.'
        }
        $env:DLSS5_CLAUDE_MODEL = 'opus[1m]'
        Set-Dlss5LaunchOverrides (Resolve-Dlss5LaunchArguments @('--host', 'claude'))
        Assert-Dlss5Equal (Select-Dlss5Agent).Model 'opus[1m]' 'Bracketed environment model was rejected.'
        $env:DLSS5_CLAUDE_MODEL = 'environment-claude'
        Assert-Dlss5Equal (Select-Dlss5Agent).Model 'environment-claude' 'Host-only launch discarded its environment model.'
        Assert-Dlss5Throws { Set-Dlss5LaunchOverrides (Resolve-Dlss5LaunchArguments @('--host', 'missing')) } ([ArgumentException]) 'Unavailable host was accepted.'
    }
    finally {
        foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
    }
}

Invoke-Dlss5Case 'host-model omitted model delegates to each host' {
    $savedAgent = $script:Dlss5SelectedAgent
    $names = @('DLSS5_CODEX_MODEL', 'DLSS5_CLAUDE_MODEL')
    $saved = @{}
    foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
    try {
        foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $null, 'Process') }
        foreach ($kind in @('codex', 'claude')) {
            $configuration = Get-Dlss5ModelConfiguration $kind
            Assert-Dlss5Equal $configuration.Model '' 'A model was pinned despite absent configuration.'
            $script:Dlss5SelectedAgent = [pscustomobject]@{ Kind = $kind; Model = $configuration.Model; Effort = $configuration.Effort }
            $prefix = @(Get-Dlss5AgentPrefixArguments -Agent $kind -GameDirectory 'game' -MachineDirectory 'machine')
            Assert-Dlss5True ($prefix -cnotcontains '--model') 'Default-model launch forced --model.'
            Assert-Dlss5True ($prefix -cnotcontains '--fallback-model') 'Default-model launch forced a fallback model.'
            Assert-Dlss5True (@($prefix | Where-Object { $null -eq $_ -or $_.Length -eq 0 }).Count -eq 0) 'Prefix contains an empty argument.'
        }
    }
    finally {
        $script:Dlss5SelectedAgent = $savedAgent
        foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
    }
}

Invoke-Dlss5Case 'host-model wrapper transports flags with prompt-file and renamed host variable' {
    $fixture = New-Dlss5IsolatedLaunchFixture -Name 'host-model-wrapper' -StubBody @('echo %4> "%DLSS5_TEST_MODEL_OUTPUT%"', 'exit /b 0')
    $null = Set-Dlss5FixtureArmed $fixture
    $outputPath = Join-Path $fixture.Root 'model.txt'
    $promptFile = Join-Path $fixture.Root 'task.txt'
    [IO.File]::WriteAllText($promptFile, 'Report the launcher version only.', [Text.UTF8Encoding]::new($false))
    $environment = @{
        LOCALAPPDATA = $fixture.LocalAppData
        DLSS5_AGENT_HOST = 'missing'
        DLSS5_AGENT = 'missing'
        DLSS5_CLAUDE_MODEL = 'environment-model'
        DLSS5_TEST_MODEL_OUTPUT = $outputPath
        HTTPS_PROXY = 'http://127.0.0.1:9'
        HTTP_PROXY = 'http://127.0.0.1:9'
        NO_PROXY = ''
    }
    $process = Invoke-Dlss5ProcessWithInput -FilePath 'cmd.exe' -Arguments @('/d', '/c', $fixture.Updater, '--host', $fixture.Stub, '--model', 'opus[1m]', '--prompt-file', $promptFile) -InputLines @() -WorkingDirectory $fixture.Game -Environment $environment
    Assert-Dlss5Equal $process.ExitCode 0 "Flag launch failed: $($process.StandardError) $($process.StandardOutput)"
    Assert-Dlss5Equal ([IO.File]::ReadAllText($outputPath).Trim()) 'opus[1m]' 'Wrapper did not pass the model unchanged.'
    $environment['DLSS5_AGENT_HOST'] = $fixture.Stub
    $process = Invoke-Dlss5ProcessWithInput -FilePath 'cmd.exe' -Arguments @('/d', '/c', $fixture.Updater, '--prompt-file', $promptFile) -InputLines @() -WorkingDirectory $fixture.Game -Environment $environment
    Assert-Dlss5Equal $process.ExitCode 0 "Renamed environment host failed: $($process.StandardError)"
    Assert-Dlss5Equal ([IO.File]::ReadAllText($outputPath).Trim()) 'environment-model' 'Environment model was lost.'
    $environment['DLSS5_CLAUDE_MODEL'] = ''
    $process = Invoke-Dlss5ProcessWithInput -FilePath 'cmd.exe' -Arguments @('/d', '/c', $fixture.Updater, '--host', $fixture.Stub, 'Report the launcher version only.') -InputLines @() -WorkingDirectory $fixture.Game -Environment $environment
    Assert-Dlss5Equal $process.ExitCode 0 "Host-only launch failed: $($process.StandardError)"
    Assert-Dlss5Equal ([IO.File]::ReadAllText($outputPath).Trim()) 'medium' 'Host-only launch did not omit the model argument.'
}

Invoke-Dlss5Case 'host-model wrapper rejects model without explicit host' {
    $root = Join-Path $script:ScratchRoot 'host-model-reject'
    New-Item -ItemType Directory -Force $root | Out-Null
    $process = Invoke-Dlss5ProcessWithInput -FilePath 'cmd.exe' -Arguments @('/d', '/c', $UpdaterPath, '--model', 'sol') -InputLines @() -WorkingDirectory $root -Environment @{ LOCALAPPDATA = $root; DLSS5_AGENT_HOST = 'codex' }
    Assert-Dlss5Equal $process.ExitCode 4 'Missing host did not fail.'
    Assert-Dlss5True $process.StandardError.Contains('--model requires an explicit --host') 'Missing host diagnostic was lost.'
    Assert-Dlss5True (-not (Test-Path -LiteralPath (Join-Path $root 'DLSS5-ADDER'))) 'Invalid flags created machine state.'
}
