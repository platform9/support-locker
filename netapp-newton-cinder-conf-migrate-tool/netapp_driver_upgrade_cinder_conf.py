#!/opt/pf9/pf9-cindervolume-base/bin/python
"""
Copyright 2017 Platform9 Systems Inc.(http://www.platform9.com)
Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at
    http://www.apache.org/licenses/LICENSE-2.0
Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
"""

# This script can be used for moving the NetApp Cinder driver related config
# options from DEFAULT section to a separate backend specific config.
# It is supposed to be used on Cinder Volume (Block storage) host under
# Platform9 Managed OpenStack and therefore script excepts the config files to
# be present in specific directories. This script will NOT restart services
# after changing the config files.

from ConfigParser import ConfigParser
from glob import glob
import argparse
import os
import sys


DEFAULT_CINDER_CONF_DIR = '/opt/pf9/etc/pf9-cindervolume-base/conf.d/'
DEFAULT_CINDER_CONF_FILE = os.path.join(DEFAULT_CINDER_CONF_DIR, 'cinder.conf')
OVERRIDE_CINDER_CONF_FILE = os.path.join(DEFAULT_CINDER_CONF_DIR, 'cinder_override.conf')
# These options listed by going through the cinder conf options for all
# the drivers mentioned on -
# http://netapp.github.io/openstack-deploy-ops-guide/newton/content/cinder.netapp.drivers.html
NETAPP_OPTIONS = [
    'netapp_server_hostname',
    'netapp_server_port',
    'netapp_login',
    'netapp_password',
    'netapp_storage_protocol',
    'netapp_transport_type',
    'netapp_copyoffload_tool_path',
    'netapp_vserver',
    'netapp_storage_family',
    'volume_driver',
    'netapp_lun_ostype',
    'netapp_lun_space_reservation',
    'netapp_host_type',
    'reserved_percentage',
    'max_oversubscription_ratio',
    'netapp_pool_name_search_pattern',
    'use_multipath_for_image_xfer',
    'filter_function',
    'goodness_function',
    'use_chap_auth',
    'nfs_shares_config',
    'nfs_mount_options',
    'nas_secure_file_permissions',
    'nas_secure_file_operations',
    'thres_avl_size_perc_start',
    'thres_avl_size_perc_stop',
    'expiry_thres_minutes',
    'netapp_size_multiplier',
    'netapp_vfiler',
    'netapp_partner_backend_name',
    'netapp_volume_list',
]


def parse_args():
    parser = argparse.ArgumentParser(
        formatter_class=argparse.RawDescriptionHelpFormatter, epilog=
        '''
        Utility for changing the way config files are setup for NetApp
        Cinder drivers
        ''')
    parser.add_argument('-d', '--config-dir', help="Cinder config directory",
                        action="store", required=False,
                        default=DEFAULT_CINDER_CONF_DIR)
    parser.add_argument('-f', '--backend-name-format',
                        help="Template for backend names",
                        action="store", default="NetAppBackend",
                        required=False)
    return parser.parse_args()


def _update_netapp_conf(orig_conf, override_config, backend_name_format):
    backend_name = backend_name_format + '01'
    override_config.set('DEFAULT', 'enabled_backends', backend_name)
    override_config.add_section(backend_name)
    override_config.set(backend_name, 'volume_backend_name', backend_name)
    for opt in NETAPP_OPTIONS:
        if orig_conf.has_option('DEFAULT', opt):
            val = orig_conf.get('DEFAULT', opt)
            override_config.set(backend_name, opt, val)
        if override_config.has_option('DEFAULT', opt):
            override_config.remove_option('DEFAULT', opt)


def verify_and_fix_config(config_files, backend_name_format):
    override_conf_path = OVERRIDE_CINDER_CONF_FILE
    if len(config_files) > 2:
        print "Multiple config files detected. Please contact " \
              "support@platform9.com"
        sys.exit(1)
    if DEFAULT_CINDER_CONF_FILE in config_files:
        default_conf = ConfigParser()
        config_files.remove(DEFAULT_CINDER_CONF_FILE)
        default_conf.read(DEFAULT_CINDER_CONF_FILE)
        if default_conf.has_option('DEFAULT', 'enabled_backends'):
            print "Cinder configuration is correct. No changes needed."
            sys.exit(0)
        if len(config_files) == 1:
            # Override conf is present
            override_conf = ConfigParser()
            override_conf.read(config_files[0])
            override_conf_path = config_files[0]
            if override_conf.has_option('DEFAULT', 'enabled_backends'):
                print "Cinder configuration is correct. No changes needed."
                sys.exit(0)
            # Take union of both configs as new file needs to be created using
            # both the configs
            default_conf.read(config_files[0])
        else:
            override_conf = ConfigParser()
        _update_netapp_conf(default_conf, override_conf, backend_name_format)
        with open(override_conf_path, 'w') as fptr:
            override_conf.write(fptr)
    else:
        print "Default cinder conf not found. Please contact " \
              "support@platform9.com"
        sys.exit(1)


def main():
    opts = parse_args()
    conf_dir = opts.config_dir
    conf_files = glob(os.path.join(conf_dir, '*.conf'))
    verify_and_fix_config(conf_files, opts.backend_name_format)


if __name__ == "__main__":
    main()

