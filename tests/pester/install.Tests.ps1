# Pester 5 unit tests for install.ps1's pure helpers — the Windows analog of
# tests/bats/os_macos.bats. The script's auto-run guard skips Invoke-ZbxMain
# when dot-sourced, so the functions can be exercised in isolation.

BeforeAll {
    $script:Installer = Join-Path $PSScriptRoot '..' '..' 'install.ps1'
    # Dot-source with harmless defaults; the guard prevents the main flow.
    . $script:Installer -DryRun
}

Describe 'Get-ZbxMsiUrl' {
    It 'builds the classic agentd latest MSI URL (7.4 amd64)' {
        Get-ZbxMsiUrl -Major '7.4' -Arch 'amd64' |
            Should -Be 'https://cdn.zabbix.com/zabbix/binaries/stable/7.4/latest/zabbix_agent-7.4-latest-windows-amd64-openssl.msi'
    }
    It 'builds the agent2 latest MSI URL (7.4 amd64)' {
        Get-ZbxMsiUrl -Major '7.4' -Arch 'amd64' -IsAgent2 |
            Should -Be 'https://cdn.zabbix.com/zabbix/binaries/stable/7.4/latest/zabbix_agent2-7.4-latest-windows-amd64-openssl.msi'
    }
    It '7.0 LTS is offered too' {
        Get-ZbxMsiUrl -Major '7.0' -Arch 'amd64' |
            Should -Be 'https://cdn.zabbix.com/zabbix/binaries/stable/7.0/latest/zabbix_agent-7.0-latest-windows-amd64-openssl.msi'
    }
}

Describe 'Get-ZbxArch' {
    It 'maps AMD64 -> amd64, and ARM64 -> amd64 (no arm64 MSI upstream; x64 emulation)' {
        Get-ZbxArch -Machine 'AMD64' | Should -Be 'amd64'
        Get-ZbxArch -Machine 'ARM64' | Should -Be 'amd64'
    }
    It 'refuses 32-bit Windows (no Zabbix build)' {
        { Get-ZbxArch -Machine 'x86' } | Should -Throw
    }
}

Describe 'parameter validation' {
    It 'rejects a Zabbix version that is not offered' {
        { & $script:Installer -ZbxVersion '6.0' -DryRun -Yes } | Should -Throw
    }
}

Describe 'Test-ZbxSignature' {
    It 'refuses an unsigned file' {
        $f = Join-Path $TestDrive 'fake.msi'
        Set-Content -Path $f -Value 'not an msi'
        Test-ZbxSignature -Path $f | Should -BeFalse
    }
    It 'refuses a valid signature from a non-Zabbix signer' {
        Mock Get-AuthenticodeSignature {
            [pscustomobject]@{
                Status            = 'Valid'
                SignerCertificate = [pscustomobject]@{ Subject = 'CN=Contoso Ltd' }
            }
        }
        Test-ZbxSignature -Path 'whatever.msi' | Should -BeFalse
    }
    It 'accepts a valid Zabbix signature' {
        Mock Get-AuthenticodeSignature {
            [pscustomobject]@{
                Status            = 'Valid'
                SignerCertificate = [pscustomobject]@{ Subject = 'CN=Zabbix SIA, O=Zabbix SIA' }
            }
        }
        Test-ZbxSignature -Path 'whatever.msi' | Should -BeTrue
    }
}

Describe '-DryRun plan and transcript' {
    It 'prints the plan and the msiexec action with SERVER/HOSTNAME, changes nothing' {
        $out = & $script:Installer -DryRun -Yes -Server '192.0.2.10' 6>&1 | Out-String
        $out | Should -Match 'Plan \(Windows agent\)'
        $out | Should -Match 'zabbix_agentd \(classic\)'
        $out | Should -Match '192\.0\.2\.10'
        $out | Should -Match 'msiexec'
        $out | Should -Match 'SERVER=192\.0\.2\.10'
        $out | Should -Match 'SERVERACTIVE=192\.0\.2\.10'
        $out | Should -Match 'HOSTNAME='
    }
    It '-Agent2 swaps in the agent2 MSI' {
        $out = & $script:Installer -DryRun -Yes -Agent2 6>&1 | Out-String
        $out | Should -Match 'Zabbix agent 2'
        $out | Should -Match 'zabbix_agent2-7\.0-latest-windows'
    }
    It '-Uninstall -DryRun plans a removal' {
        $out = & $script:Installer -DryRun -Yes -Uninstall 6>&1 | Out-String
        $out | Should -Match 'remove any installed Zabbix agent'
    }
}
