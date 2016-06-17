Add-PSSnapin VMware.VimAutomation.Core
. 'C:\Program Files (x86)\VMware\Infrastructure\vSphere PowerCLI\Scripts\Initialize-PowerCLIEnvironment.ps1'

add-type @"
    using System.Net;
    using System.Security.Cryptography.X509Certificates;
    public class TrustAllCertsPolicy : ICertificatePolicy {
        public bool CheckValidationResult(
            ServicePoint srvPoint, X509Certificate certificate,
            WebRequest request, int certificateProblem) {
            return true;
        }
    }
"@
[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy

function Format-XML ([xml]$xml, $indent=2)
{
    $StringWriter = New-Object System.IO.StringWriter
    $XmlWriter = New-Object System.XMl.XmlTextWriter $StringWriter
    $xmlWriter.Formatting = “indented”
    $xmlWriter.Indentation = $Indent
    $xml.WriteContentTo($XmlWriter)
    $XmlWriter.Flush()
    $StringWriter.Flush()
    Write-Output $StringWriter.ToString()
}

$nsxUser = "admin"
$nsxPass= ""
$nsxIP="10.4.0.39"
$nsxUri = "https://$nsxIP/api/2.0/vdn/scopes"
$vCenterIP = "vcva6-2.platform9.sys"
$vCenterUser = "root"
$vCenterPass = ""

$base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(("{0}:{1}" -f $nsxUser,$nsxPass)))

$restResult = Invoke-RestMethod -Headers @{Authorization=("Basic {0}" -f $base64AuthInfo)} -Uri $nsxUri -Method Get  -ContentType "application/xml"

Format-XML ([xml]($restResult)) -indent 4

"Record the '<vdnScopes><vdnScope><objectId>' for the transport zone"
"Record the '<vdnScopes><vdnScope><clusters><cluster><cluster><objectId>' for the Compute Cluster"
"Record the '<vdnScopes><vdnScope><clusters><cluster><cluster><scope><id>' for the Datacenter"
Read-Host -Prompt 'Press Enter to continue ...'


# Connect to vCenter
Connect-VIServer -Server $vCenterIP -User $vCenterUser -Password $vCenterPass

Get-ResourcePool | Format-List -Property Parent, Id, Name
"Record the Resource pool MoRef to place Edge Devices on"
Read-Host -Prompt 'Press Enter to continue ...'

Get-Datastore | Format-List -Property Id, Name
"Record the Datastore MoRef where the edge devices will be created (Might not be required)"
Read-Host -Prompt 'Press Enter to continue ...'

Get-View -ViewType Network | Format-list -property Name, MoRef
"Record the Port group MoRef that NSX edge devices will conenct to in order to get management instructions from the NSX Contorllers"
Read-Host -Prompt 'Press Enter to continue ...'

Get-VDSwitch | Format-list -Property Id, Name
"Record the The DVS MoRef that is used for (Either Compuete OR Edge???)"
Read-Host -Prompt 'Press Enter to continue ...'

Get-View -ViewType Network | Format-list -property Name, MoRef
"Record the Port group MoRef that NSX edge devices will conenct to in order to get management instructions from the PF9 Gateway"
Read-Host -Prompt 'Press Enter to continue ...'
