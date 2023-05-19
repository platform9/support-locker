"""
This script will fetch volumeids for given cluster_uuid, and migrate the volumes to GP3 

Details: https://platform9.atlassian.net/wiki/spaces/eng/pages/3361701917/Migarte+Qbert+AWS+cluster+to+GP3+volumes

pre-req: 
    aws credentials must be present in ~/.aws/credentials (you can add it using aws configure )
    https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-quickstart.html

python3 migrate_ebs_volume_gp2_to_gp3.py --kdu="XXXX.platform9.horse" --tenant=test --username="XXXX@platform9.com" --password="XXXXXX" --cluster_id 6d99076d-8137-444a-bcaf-e165f873a9f7

Note:
    Volume migration for master nodes are done sequentially
    for worker node we can have a batch of size 5 to migrate parallelly

    Timetaken to migrate a volume is around ~5mins

"""

import argparse
import json
import logging
import boto3
import time
import botocore
from pprint import pprint

import requests
import threading

requests.urllib3.disable_warnings()


logging.basicConfig(
    level=logging.INFO,
    format='[%(asctime)s] %(levelname)s - %(message)s',
)
logger = logging.getLogger('PF9')


class RestClient(object):
    METHODS = {
        "get": requests.get,
        "put": requests.put,
    }

    def __init__(self, token, api_version=4):
        self.token = token
        self._headers = {
            "X-Auth-Token": self.token.token
        }
        self._base_url = "https://{}/qbert/v{}/{}/".format(
            self.token.kdu, api_version, self.token.project_id)

    def _make_request(self, method_type, url):
        logger.debug("%s %s", method_type.upper(), url)
        method = self.METHODS[method_type]
        url = self._build_url(url)
        args = {
            "url": url,
            "headers": self._headers,
            "verify": False
        }
        try:
            response = method(**args)
        except Exception as err:
            raise err
        if 200 <= response.status_code < 400:
            return response
        message = "Request:{}, fail with statuscode:{}. URL:{} Reason:{}".format(
            response.request, response.status_code, response.url, response.reason)
        raise Exception(message)

    def _build_url(self, part_url):
        if part_url.startswith("/"):
            part_url = part_url.lstrip("/")
        return self._base_url + part_url

    def get(self, url):
        return self._make_request("get", url)

    def put(self, url):
        return self._make_request("put", url)


class Token():

    def __init__(self, kdu, projectname, username, password):
        self._kdu = kdu
        self._projectname = projectname
        self._username = username
        self._password = password
        self._headers = {"Content-Type": "application/json"}
        self._base_url = "https://{}/".format(
            self._kdu)
        self._token = None
        self._get_token()
        self._project_id = None
        self._get_projectid()

    @property
    def token(self):
        # If token gets expire in 24 hrs
        # time_diff = (datetime.datetime.now() -
        #              self.fetch_time).total_seconds()
        # if time_diff > 86000:
        #     logger.info("Token has expired. Fetching new token...")
        #     self._get_token()
        return self._token

    @property
    def kdu(self):
        return self._kdu

    @property
    def project_id(self):
        return self._project_id

    def _get_token(self):
        keystone_url = self._base_url + "keystone/v3/auth/tokens"
        payload = json.dumps({
            "auth": {
                "identity": {
                    "methods": [
                        "password"
                    ],
                    "password": {
                        "user": {
                            "name": self._username,
                            "domain": {
                                "name": "default"
                            },
                            "password": self._password,
                        }
                    }
                }
            }
        })

        headers = self._headers.copy()
        #self.fetch_time = datetime.datetime.now()
        response = requests.post(keystone_url, headers=headers,
                                 data=payload, verify=False, timeout=60)

        if response.status_code == 201:
            self._token = response.headers["X-Subject-Token"]
        response.raise_for_status()

    def _get_projectid(self):
        project_url = self._base_url + "keystone/v3/projects"
        headers = self._headers.copy()
        headers.update({
            "X-Auth-Token": self.token
        })
        response = requests.get(project_url, headers=headers,
                                verify=False, timeout=60)

        if response.status_code == 200:
            projects = response.json()["projects"]
            for project in projects:
                if project["name"] == self._projectname:
                    self._project_id = project["id"]

        response.raise_for_status()


class QbertAPI():
    def __init__(self, kdu, tenant, username, password):
        self.token = Token(kdu, tenant, username,
                           password)
        self.restClient = RestClient(self.token)

    def get_cluster_by_uuid(self, cluster_id):
        return self.restClient.get("clusters/{}".format(cluster_id))

    def get_nodes_by_cluster_uuid(self, cluster_id):
        master_nodes, worker_nodes = [], []
        nodes = self.restClient.get("/nodes")
        # pprint(nodes.json())
        for node in nodes.json():
            if node["clusterUuid"] == cluster_id:
                if node["isMaster"] == 0:
                    worker_nodes.append(node["cloudInstanceId"])
                else:
                    master_nodes.append(node["cloudInstanceId"])

        return master_nodes, worker_nodes


class MigrateVolume():
    def __init__(self):
        # Required credentials in shared credentials file: ~/.aws/credentials
        self.ec2_client = boto3.client('ec2')
        self.polltime = 30

    def check_modification_status(self, volume_id):
        logger.info("Fetching modfication status for volume [%s].", volume_id)
        try:
            response = self.ec2_client.describe_volumes_modifications(VolumeIds=[
                volume_id, ])
        except botocore.exceptions.ClientError as err:
            if err.response["Error"]["Code"] == "InvalidVolumeModification.NotFound":
                logger.warning(err.response["Error"]["Message"])
                return
            raise err

        while response["VolumesModifications"][0]["ModificationState"] != "completed":
            time.sleep(self.polltime)
            response = self.ec2_client.describe_volumes_modifications(VolumeIds=[
                volume_id, ])
            logger.info("Polling volume(%s) status: %s", volume_id,
                        response["VolumesModifications"][0]["ModificationState"])

        timetaken = response["VolumesModifications"][0]["EndTime"] - \
            response["VolumesModifications"][0]["StartTime"]
        logger.info("Volume modified: %s: %s. Total timetaken: %s", volume_id,
                    response["VolumesModifications"][0]["ModificationState"], timetaken)

    def migrate_volume_to_GP3(self, instance_id):
        logger.info(
            "Batch migrate_volume_to_GP3 for instance: %s ", instance_id)
        filter = [{
            'Name': 'attachment.instance-id',
            'Values': [instance_id, ]
        }]

        response = self.ec2_client.describe_volumes(Filters=filter)
        for vol in response["Volumes"]:
            volume_id = vol["VolumeId"]
            if vol["VolumeType"] == "gp2":
                logger.info("Modifiying volume: %s", volume_id)
                self.ec2_client.modify_volume(
                    VolumeId=volume_id, VolumeType='gp3')
            self.check_modification_status(volume_id)

    def batch_migrate_volumes(self, instance_ids):
        threads = []
        for i in range(len(instance_ids)):
            thread = threading.Thread(target=self.migrate_volume_to_GP3,
                                      args=(instance_ids[i],))
            threads.append(thread)

        for i in threads:
            i.start()

        for i in threads:
            i.join()


if __name__ == '__main__':

    parser = argparse.ArgumentParser()
    parser.add_argument('--kdu', type=str, required=True)
    parser.add_argument('--tenant', type=str, required=True)
    parser.add_argument('--cluster_id', type=str, required=True)
    parser.add_argument('--username', default="", type=str, required=True)
    parser.add_argument('--password', default="", type=str, required=True)

    args = parser.parse_args()

    qbertClient = QbertAPI(args.kdu, args.tenant, args.username, args.password)
    cluster_id = args.cluster_id
    migratevol = MigrateVolume()
    batchSize = 5

    try:
        # get cluster
        logger.info("Fetching cluster [%s] information.", cluster_id)
        cluster_resp = qbertClient.get_cluster_by_uuid(cluster_id)
        logger.info("cluster %s", cluster_resp.json()["name"])

        master_nodes, worker_nodes = qbertClient.get_nodes_by_cluster_uuid(
            cluster_id)

        if not (master_nodes and worker_nodes):
            logger.warning(
                "cluster %s doesn't have any master/worker nodes to migrate volume", cluster_resp.json()["name"])

        logger.info("Master nodes %s Worker nodes %s ",
                    master_nodes, worker_nodes)
        # Migrate volumes for master nodes
        for master_node in master_nodes:
            logger.info("Migrating masternode (%s) volumes to GP3",
                        cluster_resp.json()["name"])
            migratevol.migrate_volume_to_GP3(master_node)

        # Migrate volumes for worker nodes in batch of 5
        for i in range(0, len(worker_nodes), batchSize):
            logger.info("Migrating workernodes (%s) to GP3 GP3 volumetype",
                        worker_nodes[i:i + batchSize])
            migratevol.batch_migrate_volumes(worker_nodes[i:i + batchSize])
            logger.info("Migration for workernodes(%s) volumes to GP3 done!",
                        worker_nodes[i:i + batchSize])

    except Exception as err:
        logger.error("Fail to migrate volume. Error: %s", str(err))
        raise err
