@{
    UbuntuRelease     = '26.04'
    DistributionName = 'UbuntuDev-26.04'
    DefaultUser      = 'developer'
    Hostname         = 'ubuntu-dev'
    VhdSize          = '50GB'
    MinimumWsl       = '2.4.10'
    ImageOrder       = @('26.04', '24.04')
    Images           = @{
        AMD64 = @{
            '26.04' = @{
                DisplayName      = 'Ubuntu 26.04 LTS'
                DistributionName = 'UbuntuDev-26.04'
                FileName         = 'ubuntu-26.04-wsl-amd64.wsl'
                Url              = 'https://releases.ubuntu.com/resolute/ubuntu-26.04-wsl-amd64.wsl'
                Sha256SumsUrl    = 'https://releases.ubuntu.com/resolute/SHA256SUMS'
                Sha256           = '96c7f5fb28a7fe28245331f9bfbe4375f18dd29a4850116ad3c4f60f6700c55c'
            }
            '24.04' = @{
                DisplayName      = 'Ubuntu 24.04.4 LTS'
                DistributionName = 'UbuntuDev-24.04'
                FileName         = 'ubuntu-24.04.4-wsl-amd64.wsl'
                Url              = 'https://releases.ubuntu.com/noble/ubuntu-24.04.4-wsl-amd64.wsl'
                Sha256SumsUrl    = 'https://releases.ubuntu.com/noble/SHA256SUMS'
                Sha256           = '9b2f7730dc68227dd04a9f3e5eab86ad85caf556b8606ad94f1f29ff5c4fd3f5'
            }
        }
    }
}
