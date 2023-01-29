#Requires -Version 6.0
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$PSDefaultParameterValues['*:ErrorAction']='Stop'

###############################################################################################################################################################
##
## 2023, Oliver Schneider (assarbad.net)
##
## This helper script is placed into the public domain and alternatively licensed under CC0 in jurisdictions where public domain dedications have no effect.
##
## Disclaimer:
## THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
## FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
## WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
##
###############################################################################################################################################################

## NB: the idea of this script is to build libcrypto static libs, it doesn't care about libssl currently.

$funcs =
{
    $openssl = @{
        "1.1.1s" = "c5ac01e760ee6ff0dab61d6b2bbd30146724d063eb322180c6f18a6f74e4b6aa"
    }
    $nasm = @{
        "2.16.01" = "029eed31faf0d2c5f95783294432cbea6c15bf633430f254bb3c1f195c67ca3a"
    }

    <#
    .Description
    Checks the return code of the previous (native) command and throws an error with or without message, if the exit code was "unclean" (non-zero)
    #>
    function ThrowOnNativeFailure
    {
        Param($message)

        if (-not $?)
        {
            if ($message -ne $null)
            {
                $message = "Native failure: $message"
            }
            else
            {
                $message = "Unspecific native failure"
            }
            throw "$message"
        }
    }

    <#
    .Description
    Downloads a file using Invoke-WebRequest. This is suboptimal, but should be okay for this sort of script.
    #>
    function Download_File
    {
        Param (
            [Parameter(Mandatory=$true)]  [String]$url,
            [Parameter(Mandatory=$true)]  [String]$fname
        )

        $prevPreference = $global:ProgressPreference
        try
        {
            $global:ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest $url -OutFile $fname -UseBasicParsing
        }
        finally 
        {
            $global:ProgressPreference = $prevPreference
        }
    }

    <#
    .Description
    This downloads the OpenSSL version defined in $openssl and checks the file hash against the known value and then unpacks the downloaded archive.
    #>
    function Import_OpenSSL
    {
        Param (
            [Parameter(Mandatory=$true)]  [String]$tgtdir
        )

        foreach($version in $script:openssl.keys)
        {
            $url = "https://www.openssl.org/source/openssl-${version}.tar.gz"
            $fname = $url.Substring($url.LastIndexOf("/") + 1)
            if (Test-Path -Path $fname -PathType Leaf)
            {
                $host.ui.WriteErrorLine("Note: using existing file $fname. If this is not desired, remove it prior to running this script.")
            }
            else
            {
                $host.ui.WriteErrorLine("Downloading OpenSSL $version from $url as $fname")
                Download_File $url $fname
            }
            $hash = (Get-FileHash -Algorithm SHA256 -Path $fname).Hash
            if ($script:openssl.$version -eq $hash)
            {
                $dirname = "$tgtdir\openssl-${version}"
                if (Test-Path -Path $dirname) # we want the folder freshly unpacked, always
                {
                    $host.ui.WriteErrorLine("Removing existing folder $dirname")
                    Remove-Item -Path $dirname -Recurse -Force
                }
                $host.ui.WriteErrorLine("Unpacking OpenSSL $version (hash matches)")
                # bsdtar is onboard in modern Windows versions
                tar -C "$tgtdir" -xf "$fname" | Out-Null
                ThrowOnNativeFailure "Failed to unpack $fname"
                if (!(Test-Path -Path $dirname))
                {
                    throw "Expected to find a folder named '$dirname' after unpacking the archive."
                }
                return $dirname
            }
            else
            {
                throw "The expected ($script:openssl.$version) and actual hashes ($hash) don't match for $fname!"
            }
        }
    }

    <#
    .Description
    This downloads the NASM version defined in $nasm and checks the file hash against the known value and then unpacks the downloaded archive.
    #>
    function Import_NASM
    {
        Param (
            [Parameter(Mandatory=$true)]  [String]$tgtdir
        )

        foreach($version in $script:nasm.keys)
        {
            $url = "https://www.nasm.us/pub/nasm/releasebuilds/$version/win64/nasm-${version}-win64.zip"
            $fname = $url.Substring($url.LastIndexOf("/") + 1)
            if (Test-Path -Path $fname -PathType Leaf)
            {
                $host.ui.WriteErrorLine("Note: using existing file $fname. If this is not desired, remove it prior to running this script.")
            }
            else
            {
                $host.ui.WriteErrorLine("Downloading NASM $version from $url as $fname")
                Download_File $url $fname
            }
            $hash = (Get-FileHash -Algorithm SHA256 -Path $fname).Hash
            if ($script:nasm.$version -eq $hash)
            {
                $dirname = "$tgtdir\nasm-${version}"
                if (Test-Path -Path $dirname) # we want the folder freshly unpacked, always
                {
                    $host.ui.WriteErrorLine("Removing existing folder $dirname")
                    Remove-Item -Path $dirname -Recurse -Force
                }
                $host.ui.WriteErrorLine("Unpacking NASM $version (hash matches)")
                Expand-Archive -Path $fname -DestinationPath $tgtdir -Force
                if (!(Test-Path -Path $dirname))
                {
                    throw "Expected to find a folder named '$dirname' after unpacking the archive."
                }
                return $dirname
            }
            else
            {
                throw "The expected ($script:nasm.$version) and actual hashes ($hash) don't match for $fname!"
            }
        }
    }

    <#
    .Description
    This uses the known (and hardcoded) location of vswhere.exe to determine the latest Visual Studio, given the version range from $vsrange!
    #>
    function Get_VSBasePath
    {
        Param($vsrange = "[16.0,18.0)")

        $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
        $vspath = & $vswhere -products "*" -format value -property installationPath -latest -version "$vsrange"
        ThrowOnNativeFailure "Failed to retrieve path to Visual Studio installation (range: $vsrange)"
        return $vspath
    }

    function Copy_Finished
    {
        Param (
            [Parameter(Mandatory=$true)]  [String]$source,
            [Parameter(Mandatory=$true)]  [String]$target
        )
        Copy-Item -Force "$source" "$target"
        return $True
    }

    <#
    .Description
    Determines if sccache is available.
    #>
    function Get_sccache
    {
        return Get-Command sccache -CommandType Application -ErrorAction silentlycontinue
    }

    <#
    .Description
    Patches the OpenSSL makefile to get rid of some garbage, such as this perpetuated silliness of creating PDBs for static libs ...
    #>
    function Patch_Makefile
    {
        $ccache = Get_sccache
        $cl = "cl"
        if ($ccache -ne $null)
        {
            $cl = "$ccache $cl"
        }
        # Patch the makefile so that the debug info is embedded in the object files (/Z7)
        echo "Patching makefile ..."
        Move-Item -Force .\makefile .\makefile.unpatched
        (Get-Content .\makefile.unpatched) `
            -replace '^(LIB_CFLAGS=)/Zi /Fdossl_static.pdb(.+)$', '$1/Brepro /Z7$2' `
            -replace '^(LDFLAGS=/nologo)( /debug)(.*)$', '$1$3 /Brepro' `
            -replace '^CC=cl$', "CC=$cl" |
        Out-File .\makefile
    }

    <#
    .Description
    This builds libcrypto by invoking the correct commands in the correct order (as of OpenSSL 1.1.x)
    #>
    function Build_And_Place_LibCrypto
    {
        Param (
            [Parameter(Mandatory=$true)]  [String]$arch,
            [Parameter(Mandatory=$true)]  [String]$ossl_target,
            [Parameter(Mandatory=$true)]  [String]$target_fname,
            [Parameter(Mandatory=$true)]  [String]$ossl_hdrs,
            [Parameter(Mandatory=$true)]  [String]$staging
        )
        $tgtdir = "$staging\$pid"
        $parentpath = "$pwd"
        Write-Host "Current job [$pid]: ${arch}: $ossl_target, $target_fname, $ossl_hdrs`n`$tgtdir = $tgtdir`n`$parentpath = $parentpath"

        if (-not (Test-Path -Path "$tgtdir" -PathType Container))
        {
            New-Item -Type Directory "$tgtdir"
        }

        $nasmdir = Import_NASM $tgtdir
        # Make our copy of NASM available
        $env:PATH =  $nasmdir + ";" + $env:PATH
        echo "NASM: $nasmdir"

        $vspath = Get_VSBasePath
        Import-Module "$vspath\Common7\Tools\Microsoft.VisualStudio.DevShell.dll" -Force -cmdlet Enter-VsDevShell
        Enter-VsDevShell -VsInstallPath "$vspath" -DevCmdArguments "-arch=$arch -no_logo" -SkipAutomaticLocation
        $ossldir = Import_OpenSSL $tgtdir
        Write-Host "OpenSSL dir: $ossldir"
        Push-Location -Path "$ossldir"

        # Probably a good idea also to add (needs to be validated!): no-autoalginit no-autoerrinit
        & perl Configure $ossl_target --api=1.1.0 --release threads no-shared no-filenames | Out-Host
        ThrowOnNativeFailure "Failed to configure OpenSSL for build ($ossl_target, $arch, $target_fname)"
        # Fix up the makefile to fit our needs better
        Patch_Makefile
        & nmake /nologo include\crypto\bn_conf.h include\crypto\dso_conf.h include\openssl\opensslconf.h libcrypto.lib | Out-Host
        ThrowOnNativeFailure "Failed to build OpenSSL ($ossl_target, $arch, $target_fname)"
        $libpath = "$parentpath\lib"
        if (-not (Test-Path -Path "$libpath" -PathType Container))
        {
            New-Item -Type Directory "$libpath"
        }
        Copy_Finished .\libcrypto.lib "$libpath\$target_fname"
        Copy-Item -Recurse .\include\openssl "$parentpath\include\$ossl_hdrs"

        Pop-Location
    }

    <#
    .Description
    Checks if Perl is available and if not found kicks off an _interactive_ installation of StrawberryPerl via winget (i.e. user can still choose to cancel).
    #>
    function Check_Perl_Available
    {
        $perl = Get-Command perl -CommandType Application -ErrorAction silentlycontinue
        if ($perl -eq $null)
        {
            echo "NOTE: You need to have Perl installed for this build for work. Kicking off the installation. Feel free to cancel, but be aware that the build will fail."
            winget install --accept-package-agreements --accept-source-agreements --exact --interactive --id StrawberryPerl.StrawberryPerl
        }
    }
} # $funcs

$targets = @{ x86=@("VC-WIN32", "libcrypto32.lib", "openssl32"); x64=@("VC-WIN64A", "libcrypto64.lib", "openssl64") }
$logpath = "$PSScriptRoot\build-openssl-libcrypto.log"
$staging = "$pwd\staging"
Start-Transcript -Path $logpath -Append

$funcs:Check_Perl_Available

foreach($tgt in $targets.GetEnumerator())
{
    $arch = $($tgt.Name)
    $ossl_target, $target_fname, $ossl_hdrs = $($tgt.Value)
    Write-Host "Before starting job: ${arch}: $ossl_target, $target_fname, $ossl_hdrs"
    Start-Job -InitializationScript $funcs -Name "OpenSSL build: $($tgt.Name)" -ScriptBlock { Build_And_Place_LibCrypto $using:arch $using:ossl_target $using:target_fname $using:ossl_hdrs $using:staging }
}

while (Get-Job -State "Running")
{
    Clear-Host
    Get-Job
    Start-Sleep 2
}

# Write output from the jobs (commented out, because we have a log file)
# Get-Job | Receive-Job
# Remove jobs from queue
Get-Job | Remove-Job

Stop-Transcript
