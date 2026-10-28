<#
  Install / update the Emirates ID Card Toolkit Service from GitHub (encrypted package).

  Manual install (admin PowerShell) - asks for the package password:
      irm https://raw.githubusercontent.com/naveen7355/EID_MOHRE/main/install-eid.ps1 | iex

  What it does
  - Checks the latest GitHub Release. If this PC already has it -> stops (no password asked).
  - Downloads EID_MOHRE.bin, asks for the password, verifies and decrypts it.
  - Clean reinstall on every new release, ONLY for "Emirates ID Card Toolkit Service":
    removes that service + C:\Program Files (x86)\Emirates ID Card Toolkit Service (configs backed up
    to C:\ProgramData\EID_MOHRE), then installs the MSI there again.
    Other toolkit services (e.g. ICAToolkit) are never touched.
  - Copies the new config_* files in and starts the service as 'Emirates ID Card Toolkit Service'.
  - Log: C:\Windows\Temp\EID_MOHRE-deploy.log
#>
param(
    [string]$Password,       # optional: give the password without a prompt
    [string]$PasswordFile    # optional: read the password from a file (e.g. a restricted share)
)

$Repo      = "naveen7355/EID_MOHRE"
$AssetName = "EID_MOHRE.bin"
$Product   = "Emirates ID Card Toolkit Service"
$RegKey    = "HKLM:\SOFTWARE\EID_MOHRE"

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Security
Start-Transcript -Path "$env:WINDIR\Temp\EID_MOHRE-deploy.log" -Append | Out-Null
$Work = $null

$TargetDir   = Join-Path $(if (${env:ProgramFiles(x86)}) { ${env:ProgramFiles(x86)} } else { $env:ProgramFiles }) $Product
$ServiceDisp = "Emirates ID Card Toolkit Service"   # display name shown in services.msc

function Get-Installed {
    $paths = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
             "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    Get-ItemProperty $paths -ErrorAction SilentlyContinue | Where-Object DisplayName -eq $Product | Select-Object -First 1
}
function Get-SvcExe($svc) {
    ($svc.PathName -replace '^"([^"]+)".*$', '$1') -replace '\.exe\s+.*$', '.exe'
}
# All toolkit services on the PC (any folder) - used only to PROTECT the ones we must not touch
function Get-ToolkitServices {
    Get-CimInstance Win32_Service | Where-Object { $_.PathName -like "*EIDAToolkitService.exe*" -or $_.PathName -like "*ICAToolkit*" }
}
function Test-InTarget([string]$path) { $path -and $path.TrimEnd('\').StartsWith($TargetDir, [StringComparison]::OrdinalIgnoreCase) }
# Only the "Emirates ID Card Toolkit Service": by display name, or running from the target folder
function Get-EmiratesServices {
    Get-ToolkitServices | Where-Object { $_.Name -eq "ICAToolkitService" -or $_.DisplayName -eq $ServiceDisp -or (Test-InTarget (Get-SvcExe $_)) }
}
function Get-TargetService {
    Get-ToolkitServices | Where-Object { Test-InTarget (Get-SvcExe $_) } | Select-Object -First 1
}
# Where the registered MSI really lives (path of its EIDAToolkitService.exe component)
function Get-RegisteredExe($productCode) {
    try {
        $wi = New-Object -ComObject WindowsInstaller.Installer
        $wi.ComponentPath($productCode, "{D34D7FD1-31B2-5F8D-9C4F-64A73D251BD8}")
    } catch { $null }
}
# MOHRE's MSI cannot be uninstalled normally: its service/delete steps run during uninstall in a folder
# that no longer exists (error 1721). Disable those 3 steps in Windows' cached copy of the installed MSI,
# then uninstall. The services are handled by this script itself.
function Invoke-CleanUninstall($productCode) {
    $local = Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products" -ErrorAction SilentlyContinue |
             ForEach-Object { Get-ItemProperty (Join-Path $_.PSPath "InstallProperties") -ErrorAction SilentlyContinue } |
             Where-Object { $_.DisplayName -eq $Product } | Select-Object -First 1 -ExpandProperty LocalPackage
    $local = [string]$local   # plain string - COM rejects PowerShell-wrapped objects
    if ($local -and (Test-Path $local)) {
        $bk = Join-Path $env:ProgramData "EID_MOHRE"; New-Item -ItemType Directory $bk -Force | Out-Null
        Copy-Item $local (Join-Path $bk ("cached_" + (Split-Path $local -Leaf))) -Force
        (Get-Item $local).IsReadOnly = $false
        $wi = New-Object -ComObject WindowsInstaller.Installer
        $db = $wi.GetType().InvokeMember("OpenDatabase", "InvokeMethod", $null, $wi, @([string]$local, [int]1))
        foreach ($a in "ExecInstallService", "ExecRemoveService", "ExecDeleteFiles") {
            $v = $db.GetType().InvokeMember("OpenView", "InvokeMethod", $null, $db, @([string]"UPDATE ``InstallExecuteSequence`` SET ``Condition`` = '0' WHERE ``Action`` = '$a'"))
            [void]$v.GetType().InvokeMember("Execute", "InvokeMethod", $null, $v, $null)
            [void]$v.GetType().InvokeMember("Close", "InvokeMethod", $null, $v, $null)
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($v)
        }
        [void]$db.GetType().InvokeMember("Commit", "InvokeMethod", $null, $db, $null)
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($db)
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($wi)
        [GC]::Collect(); [GC]::WaitForPendingFinalizers()
        Write-Output "Patched cached installer ($local) so it can uninstall"
    } else { Write-Warning "Cached installer not found - trying a normal uninstall" }
    $ulog = "$env:WINDIR\Temp\EID_MOHRE-uninstall.log"
    $p = Start-Process msiexec.exe -ArgumentList "/x $productCode /qn /norestart /L*v `"$ulog`"" -Wait -PassThru
    if ($p.ExitCode -notin 0, 3010, 1605) { throw "Uninstall of the old version failed (exit $($p.ExitCode)). See $ulog" }
    Write-Output "Old version uninstalled"
}
function Test-TargetInstalled { (Test-Path (Join-Path $TargetDir "EIDAToolkitService.exe")) -and (Get-TargetService) }

try {
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $admin) { throw "Run PowerShell as Administrator." }

    # 1. Latest release - stop early if already up to date
    $h = @{ "User-Agent" = "EID_MOHRE-installer"; "Accept" = "application/vnd.github+json" }
    $rel = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/latest" -Headers $h
    $tag = $rel.tag_name
    $cur = (Get-ItemProperty $RegKey -Name Version -ErrorAction SilentlyContinue).Version
    Write-Output "Latest release: $tag   Installed: $(if ($cur) { $cur } else { 'none' })"
    if ($cur -eq $tag -and (Test-TargetInstalled)) { Write-Output "Already up to date."; return }

    $asset = $rel.assets | Where-Object name -eq $AssetName | Select-Object -First 1
    if (-not $asset) { throw "Release $tag has no $AssetName attached." }

    # 2. Password
    if (-not $Password -and $PasswordFile) { $Password = (Get-Content $PasswordFile -Raw).Trim() }
    if (-not $Password) {
        $s = Read-Host "Package password" -AsSecureString
        $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
        try { $Password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
    }

    # 3. Download
    $Work = Join-Path $env:WINDIR ("Temp\EID_MOHRE_" + [guid]::NewGuid())
    New-Item -ItemType Directory $Work -Force | Out-Null
    $bin = Join-Path $Work $AssetName
    Write-Output "Downloading $AssetName ($([math]::Round($asset.size/1MB,1)) MB)"
    $dh = $h.Clone(); $dh.Accept = "application/octet-stream"
    Invoke-WebRequest -Uri $asset.url -Headers $dh -OutFile $bin -UseBasicParsing

    # 4. Verify + decrypt   (format: "EIDPK1" | salt16 | iv16 | ciphertext | hmac32)
    $data = [IO.File]::ReadAllBytes($bin)
    if ($data.Length -lt 6 + 16 + 16 + 16 + 32 -or [Text.Encoding]::ASCII.GetString($data, 0, 6) -ne "EIDPK1") { throw "Not a valid EID package file." }
    $salt = New-Object byte[] 16; [Array]::Copy($data, 6, $salt, 0, 16)
    $iv   = New-Object byte[] 16; [Array]::Copy($data, 22, $iv, 0, 16)
    $bodyLen = $data.Length - 32
    $kdf  = New-Object Security.Cryptography.Rfc2898DeriveBytes($Password, $salt, 200000, [Security.Cryptography.HashAlgorithmName]::SHA256)
    $keys = $kdf.GetBytes(64)
    [byte[]]$encKey = $keys[0..31]; [byte[]]$macKey = $keys[32..63]
    $mac = (New-Object Security.Cryptography.HMACSHA256(,$macKey)).ComputeHash($data, 0, $bodyLen)
    $diff = 0; for ($i = 0; $i -lt 32; $i++) { $diff = $diff -bor ($mac[$i] -bxor $data[$bodyLen + $i]) }
    if ($diff -ne 0) { throw "Wrong password (or the package is damaged)." }
    $aes = [Security.Cryptography.Aes]::Create()
    $aes.KeySize = 256; $aes.Mode = "CBC"; $aes.Padding = "PKCS7"; $aes.Key = $encKey; $aes.IV = $iv
    $plain = $aes.CreateDecryptor().TransformFinalBlock($data, 38, $bodyLen - 38)
    $zip = Join-Path $Work "pkg.zip"; [IO.File]::WriteAllBytes($zip, $plain)
    $pkg = Join-Path $Work "pkg"; Expand-Archive $zip -DestinationPath $pkg -Force
    Write-Output "Package verified and decrypted."

    # 5. Clean reinstall of the "Emirates ID Card Toolkit Service" ONLY.
    #    Any other toolkit service (e.g. ICAToolkit in C:\Program Files\ICAToolkitService) is NOT touched.
    $msi = Get-ChildItem $pkg -Filter *.msi | Select-Object -First 1
    if (-not $msi) { throw "This package has no MSI - cannot do a clean install." }
    $msiHash = (Get-FileHash $msi.FullName -Algorithm SHA256).Hash
    Write-Output "Target folder: $TargetDir"

    # Remember the OTHER toolkit services exactly as they are, so they can be restored if anything removes them
    $protect = @(Get-ToolkitServices | Where-Object { -not (Test-InTarget (Get-SvcExe $_)) -and $_.DisplayName -ne $ServiceDisp -and $_.Name -ne "ICAToolkitService" } |
                 Select-Object Name, DisplayName, PathName, StartMode, State)
    foreach ($o in $protect) { Write-Output "Leaving untouched: '$($o.DisplayName)' ($($o.Name)) -> $($o.PathName)" }

    # Is the registered MSI installed somewhere else (i.e. it IS one of the protected installs)?
    $inst = Get-Installed
    if ($inst) {
        $regExe = Get-RegisteredExe $inst.PSChildName
        if ($regExe -and -not (Test-InTarget $regExe)) {
            throw "The MSI is registered for $(Split-Path $regExe -Parent), not $TargetDir. Uninstalling it would remove that install, so nothing was changed. Remove it manually first if you want it replaced."
        }
    }

    $emirates = @(Get-EmiratesServices)
    if ($emirates -or (Test-Path $TargetDir) -or $inst) {
        Write-Output "Existing 'Emirates ID Card Toolkit Service' found - removing it for a clean install"

        # 5a. Back up its config files to C:\ProgramData\EID_MOHRE\backup_<date>
        $old = Get-ChildItem $TargetDir -Filter "config_*" -File -ErrorAction SilentlyContinue
        if ($old) {
            $bak = Join-Path $env:ProgramData ("EID_MOHRE\backup_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
            New-Item -ItemType Directory $bak -Force | Out-Null; $old | Copy-Item -Destination $bak -Force
            Write-Output "Old config files backed up to $bak"
        }
        # 5b. Stop + delete only the Emirates service(s)
        foreach ($s in $emirates) {
            Write-Output "Removing service '$($s.DisplayName)' ($($s.Name))"
            Stop-Service -Name $s.Name -Force -ErrorAction SilentlyContinue
            & sc.exe delete "$($s.Name)" | Out-Null
        }
        Get-Process EIDAToolkitService -ErrorAction SilentlyContinue | Where-Object { Test-InTarget $_.Path } | Stop-Process -Force
        Start-Sleep -Seconds 2
        # 5c. Uninstall the old MSI (with MOHRE's broken uninstall steps switched off)
        if ($inst) { Invoke-CleanUninstall $inst.PSChildName; Start-Sleep -Seconds 3 }
        # 5d. Delete the target folder only
        if (Test-Path $TargetDir) { Write-Output "Deleting $TargetDir"; Remove-Item $TargetDir -Recurse -Force -ErrorAction SilentlyContinue }
    } else { Write-Output "No existing 'Emirates ID Card Toolkit Service' - fresh install" }

    # 5e. Fresh install into the target folder
    $log = "$env:WINDIR\Temp\EID_MOHRE-msi.log"
    Write-Output "Installing $($msi.Name) to $TargetDir"
    $p = Start-Process msiexec.exe -ArgumentList "/i `"$($msi.FullName)`" INSTALLDIR=`"$TargetDir\`" /qn /norestart /L*v `"$log`"" -Wait -PassThru
    if ($p.ExitCode -notin 0, 3010, 1641) { throw "MSI install failed (exit $($p.ExitCode)). See $log" }
    Start-Sleep -Seconds 5
    if (-not (Test-Path (Join-Path $TargetDir "EIDAToolkitService.exe"))) { throw "MSI finished but EIDAToolkitService.exe is not in $TargetDir. See $log" }

    # 5f. Safety net: put back any protected service that disappeared
    foreach ($o in $protect) {
        if (-not (Get-Service -Name $o.Name -ErrorAction SilentlyContinue)) {
            Write-Warning "Service '$($o.Name)' was removed by the installer - restoring it"
            $start = if ($o.StartMode -eq "Auto") { "auto" } elseif ($o.StartMode -eq "Disabled") { "disabled" } else { "demand" }
            & sc.exe create "$($o.Name)" binPath= "$($o.PathName)" DisplayName= "$($o.DisplayName)" start= $start | Out-Null
            if ($o.State -eq "Running") { Start-Service -Name $o.Name -ErrorAction SilentlyContinue }
        }
    }

    # 6. Copy the new config files into the target folder
    $cfg = Get-ChildItem $pkg -File | Where-Object { $_.Extension -ne ".msi" }
    $svc = Get-TargetService
    if ($svc -and $svc.State -eq "Running") { Stop-Service -Name $svc.Name -Force; Start-Sleep -Seconds 2 }
    foreach ($f in $cfg) {
        Copy-Item $f.FullName (Join-Path $TargetDir $f.Name) -Force
        Write-Output "Installed $($f.Name)"
    }

    # 7. Service: make sure it exists, set its display name, start it
    $svc = Get-TargetService
    if (-not $svc) {
        Write-Output "Registering the toolkit service"
        Start-Process (Join-Path $TargetDir "EIDAToolkitService.exe") -ArgumentList "-install" -WorkingDirectory $TargetDir -Wait -WindowStyle Hidden
        Start-Sleep -Seconds 3
        $svc = Get-TargetService
    }
    if (-not $svc) { throw "Toolkit service was not created. Check $TargetDir" }
    & sc.exe config "$($svc.Name)" DisplayName= "$ServiceDisp" start= auto | Out-Null
    & sc.exe description "$($svc.Name)" "$ServiceDisp" | Out-Null
    $other = Get-Service ICAToolkit -ErrorAction SilentlyContinue
    if ($other -and $other.Status -eq "Running") {
        Write-Warning "ICAToolkit (old toolkit) is also running. Both use the same agent, so only ONE can work at a time."
    }
    try {
        Start-Service -Name $svc.Name
        Start-Sleep -Seconds 3
        $state = (Get-Service -Name $svc.Name).Status
        Write-Output "Service '$ServiceDisp' (name: $($svc.Name)) is $state - $TargetDir"
    } catch {
        Write-Warning "Installed, but '$ServiceDisp' could not start: $($_.Exception.Message)"
    }

    # 8. Remember what is installed
    New-Item $RegKey -Force | Out-Null
    Set-ItemProperty $RegKey -Name Version -Value $tag
    if ($msi) { Set-ItemProperty $RegKey -Name MsiHash -Value $msiHash }
    Set-ItemProperty $RegKey -Name Updated -Value (Get-Date -Format "yyyy-MM-dd HH:mm")
    Write-Output "Done: EID Toolkit $tag installed."
}
catch {
    Write-Output "ERROR: $($_.Exception.Message)"
    $global:LASTEXITCODE = 1
}
finally {
    $Password = $null
    if ($Work -and (Test-Path $Work)) { Remove-Item $Work -Recurse -Force -ErrorAction SilentlyContinue }
    Stop-Transcript | Out-Null
}
