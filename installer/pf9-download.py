#!/usr/bin/python2

import base64
import httplib
import json
import sys
import zlib

def get_token_v2(url, username, password):
    """
    Returns OpenStack identity token using
    Keystone v2 API
    """
    conn = httplib.HTTPSConnection(url)
    headers = { "Content-type": "application/json" }
    body = { "auth": {
               "passwordCredentials": {
                  "username": "{0}".format(username),
                  "password": "{0}".format(password)
               },
               "tenantName": "service"
             }
           }
    body_json = json.JSONEncoder().encode(body)

    conn.request("POST", "/keystone/v2.0/tokens", body_json, headers)
    response = conn.getresponse()

    if response.status != 200:
        print("{0}: {1}".format(response.status, response.reason))
        exit(1)

    body = json.loads(response.read())
    return body['access']['token']['id']

def download_installer(url, token, installer_name):
    conn = httplib.HTTPSConnection(url)

    # We compress the token because most browsers have a
    # max size of 4096 bytes per cookie and the Keystone
    # token exceeds this. This is only implemented for the
    # static file pipeline.
    compressed_token = base64.b64encode(zlib.compress(token))
    headers = { "X-Auth-Token": compressed_token }
    body = ""

    conn.request("GET", "/private/{0}".format(installer_name), body, headers)
    response = conn.getresponse()

    if response.status != 200:
        print("{0}: {1}".format(response.status, response.reason))
        exit(1)

    body = response.read()

    # writes the file in the current working directory
    with open(installer_name, 'w') as file:
        file.write(body)

def main():
    if len(sys.argv) != 5:
        print("A simple utility to download Platform9 installers")
        print("usage: python " + sys.argv[0] + "  <platform9_url> <username> <password> <redhat|debian>\n")
        print("redhat        | RHEL/CentOS/Scientific Linux >= 6.6 ")
        print("debian        | Ubuntu 12.04 or Ubuntu 14.04\n")
        exit(1)

    if sys.argv[4] == "redhat":
        package = "platform9-install-redhat.sh"
    elif sys.argv[4] == "debian":
        package = "platform9-install-debian.sh"
    else:
        print(sys.argv[4] + " is an unknown option")
        exit(1)

    token = get_token_v2(sys.argv[1], sys.argv[2], sys.argv[3])
    download_installer(sys.argv[1], token, package)

if __name__ == "__main__":
    main()
