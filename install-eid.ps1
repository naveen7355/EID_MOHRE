<#
  Install / update the Emirates ID Card Toolkit Service from GitHub (encrypted package).

  Manual install (admin PowerShell) - asks for the package password:
      irm https://raw.githubusercontent.com/naveen7355/EID_MOHRE/main/install-eid.ps1 | iex

  What it does
  - Checks the latest GitHub Release. If this PC already has it -> stops (no password asked).
  - Downloads EID_MOHRE.bin, asks for the password, verifies and decrypts it.
  - Installs the MSI if the toolkit is missing (or if the MSI in the release changed).
  - Copies the config_* files into the install folder and restarts the toolkit service.
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

function Get-Installed {
    $paths = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
             "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    Get-ItemProperty $paths -ErrorAction SilentlyContinue | Where-Object DisplayName -eq $Product | Select-Object -First 1
}
function Get-InstallDir {
    foreach ($base in ${env:ProgramFiles(x86)}, $env:ProgramFiles) {
        if ($base -and (Test-Path (Join-Path $base "$Product\EIDAToolkitService.exe"))) { return (Join-Path $base $Product) }
    }
    return $null
}
function Get-ToolkitService {
    Get-CimInstance Win32_Service | Where-Object { $_.PathName -like "*EIDAToolkitService.exe*" } | Select-Object -First 1
}

try {
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $admin) { throw "Run PowerShell as Administrator." }

    # 1. Latest release - stop early if already up to date
    $h = @{ "User-Agent" = "EID_MOHRE-installer"; "Accept" = "application/vnd.github+json" }
    $rel = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/latest" -Headers $h
    $tag = $rel.tag_name
    $cur = (Get-ItemProperty $RegKey -Name Version -ErrorAction SilentlyContinue).Version
    Write-Output "Latest release: $tag   Installed: $(if ($cur) { $cur } else { 'none' })"
    if ($cur -eq $tag -and (Get-Installed)) { Write-Output "Already up to date."; return }

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

    # 5. Install / reinstall the MSI when needed
    $msi = Get-ChildItem $pkg -Filter *.msi | Select-Object -First 1
    $installed = Get-Installed
    if ($msi) {
        $msiHash = (Get-FileHash $msi.FullName -Algorithm SHA256).Hash
        $oldHash = (Get-ItemProperty $RegKey -Name MsiHash -ErrorAction SilentlyContinue).MsiHash
        if ($installed -and $oldHash -and $oldHash -ne $msiHash) {
            Write-Output "New MSI in this release - removing old version first"
            $code = $installed.PSChildName
            $p = Start-Process msiexec.exe -ArgumentList "/x $code /qn /norestart" -Wait -PassThru
            if ($p.ExitCode -notin 0, 3010, 1605) { throw "Uninstall failed (exit $($p.ExitCode))." }
            $installed = $null
        }
        if (-not $installed) {
            Write-Output "Installing $($msi.Name)"
            $log = "$env:WINDIR\Temp\EID_MOHRE-msi.log"
            $p = Start-Process msiexec.exe -ArgumentList "/i `"$($msi.FullName)`" /qn /norestart /L*v `"$log`"" -Wait -PassThru
            if ($p.ExitCode -notin 0, 3010, 1641) { throw "MSI install failed (exit $($p.ExitCode)). See $log" }
            Start-Sleep -Seconds 5
        } else { Write-Output "Toolkit already installed - updating config files only." }
    } elseif (-not $installed) { throw "Toolkit is not installed and this package has no MSI." }

    # 6. Copy config files + restart the service
    $dir = Get-InstallDir
    if (-not $dir) { throw "Install folder not found after installation." }
    $cfg = Get-ChildItem $pkg -File | Where-Object { $_.Extension -ne ".msi" }
    $svc = Get-ToolkitService
    if ($svc -and $svc.State -eq "Running") { Stop-Service -Name $svc.Name -Force; Start-Sleep -Seconds 2 }
    if ($cfg) {
        $bak = Join-Path $dir ("_backup_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
        New-Item -ItemType Directory $bak -Force | Out-Null
        foreach ($f in $cfg) {
            $target = Join-Path $dir $f.Name
            if (Test-Path $target) { Copy-Item $target $bak -Force }
            Copy-Item $f.FullName $target -Force
            Write-Output "Updated $($f.Name)"
        }
    }
    $svc = Get-ToolkitService
    if ($svc) {
        Set-Service -Name $svc.Name -StartupType Automatic
        Start-Service -Name $svc.Name
        Write-Output "Service '$($svc.Name)' running."
    } else { Write-Warning "Toolkit service not found - check the installation." }

    # 7. Remember what is installed
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
