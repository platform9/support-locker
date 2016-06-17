$osTenant = "service"
$osUsername = "cody@platform9.com"
$osPassword = ""
$osIdentityEndpoint = "https://pf9-vmw.platform9.net/keystone_admin/v2.0"
$osrResManEndpoint = "https://pf9-nsx-04.platform9.net/resmgr/v1/services/nsx-neutron-server"

Function osAuth($osT, $osU, $osP, $osI, $osR){
  $authJSON = '{"auth": {"tenantName": "' + $osT + '","passwordCredentials": {"username": "' + $osU + '","password": "' + $osP + '"}}}'
  $authResult = Invoke-RestMethod -Method Post -Uri "$osI/tokens" -Body ($authJSON) -ContentType 'application/json' -Headers @{'Accept'='application/json'}
  $services = @{}
  ForEach($svc in $authResult.access.serviceCatalog){
    $services += @{$svc.type = @{'name' = $svc.name; 'url' = $svc.endpoints[0].publicURL}}
  }
  $services += @{'identity_admin' = @{'name' = 'keystone_admin'; 'url' = $osI}}
  $tenantAuth = @{}
  $tenantAuth += @{'services' = $services}
  $tenantAuth += @{'token' = $authResult.access.token.id}
  $tenantAuth += @{'tenantId' = $authResult.access.token.tenant.id}
  $tenantAuth += @{'userId' = $authResult.access.user.id}
  return $tenantAuth
}

$serviceAuth = osAuth $osTenant $osUsername $osPassword $osIdentityEndpoint $osRegion

$postBody = '{
               "nsx": {
                 "nsxv": {
                   "user": "",
                   "password": "",
                   "cluster_moid": "",
                   "datacenter_moid": "",
                   "resource_pool_id": "",
                   "datastore_id": "",
                   "external_network": "",
                   "dvs_id": "",
                   "mgt_net_moid": ""
                 }
               },
               "configured": true,
               "neutron": {}
             }'
$configNSX = Invoke-RestMethod -Method Post -Uri ($osrResManEndpoint) -ContentType 'application/json' -Body ($postBody) -Headers @{'X-Auth-Token'=$serviceAuth.token}

