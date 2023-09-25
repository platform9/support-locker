import argparse
import boto3
import math
import logging
import time
import botocore
import threading

AWS_REGION_ID=''
AWS_ACCESS_KEY_ID=''
AWS_SECRET_ACCESS_KEY=''

logging.basicConfig(
    level=logging.INFO,
    format='[%(asctime)s] %(levelname)s - %(message)s',
)
logger = logging.getLogger('PF9')

class MigrateVolume:
    def __init__(self):
        self.ec2_client = boto3.client('ec2', aws_access_key_id=AWS_ACCESS_KEY_ID, aws_secret_access_key=AWS_SECRET_ACCESS_KEY, region_name=AWS_REGION_ID)
        self.polltime = 30

    def calculate_iops(self, volume_size, iops_per_gb):
        iops = min(math.ceil(volume_size * iops_per_gb), 64000)
        return iops
    
    def check_modification_status(self, volume_id):
        logger.info("Fetching modfication status for volume [%s].", volume_id)
        try:
            response = self.ec2_client.describe_volumes_modifications(VolumeIds=[volume_id])
        except botocore.exceptions.ClientError as err:
            if err.response["Error"]["Code"] == "InvalidVolumeModification.NotFound":
                logger.warning(err.response["Error"]["Message"])
                return
            raise err

        if len(response["VolumesModifications"]) < 1:
            logger.warning("Volume with id (%s) Not Found", volume_id)
            return

        while response["VolumesModifications"][0]["ModificationState"] != "completed" and response["VolumesModifications"][0]["ModificationState"] != "failed":
            time.sleep(self.polltime)
            response = self.ec2_client.describe_volumes_modifications(VolumeIds=[volume_id])
            logger.info("Polling volume(%s) status: %s, progress: %s", volume_id, response["VolumesModifications"][0]["ModificationState"], response["VolumesModifications"][0]["Progress"])

        timetaken = response["VolumesModifications"][0]["EndTime"] - response["VolumesModifications"][0]["StartTime"]
        logger.info("Volume modified: %s: %s. Total timetaken: %s", volume_id, response["VolumesModifications"][0]["ModificationState"], timetaken)

    def modify_volume_to_io2(self, volume_id, iops_per_gb):
        logger.info('Modifying volume %s to io2', volume_id)

        try:
            # Get volume info.
            response = self.ec2_client.describe_volumes(VolumeIds=[volume_id])
            
            if len(response["Volumes"]) < 1:
                logger.warning("Volume with id (%s) Not Found", volume_id)
                return
            volume_info = response['Volumes'][0]

            # Calculate iops based on the volume size and IOPS/GB
            iops = self.calculate_iops(volume_info['Size'], iops_per_gb)

            logger.info('Modifying volume %s to io2 with the following parameters:- IOPS/GB: %s, IOPS: %s', volume_id, iops_per_gb, iops)
            # Modify the volume to io2 and set the IOPS and throughput.
            self.ec2_client.modify_volume(
                VolumeId=volume_id,
                VolumeType='io2',
                Iops=iops
            )

            self.check_modification_status(volume_id)

            logger.info('Successfully modified volume %s to io2', volume_id)
        except Exception as e:
            logger.error('Failed to modify volume %s to io2: %s', volume_id, e)

    def modify_volumes_to_io2(self, volume_ids, iops_per_gb):
        threads = []

        for volume_id in volume_ids:
            thread = threading.Thread(target=self.modify_volume_to_io2, args=(volume_id, iops_per_gb))
            threads.append(thread)

        for t in threads:
            t.start()

        for t in threads:
            t.join()

def validate_iops_per_gb(iops_per_gb):
    if iops_per_gb < 1 or iops_per_gb > 500:
        logger.error('IOPS/GB must be between 1 and 500')
        raise SystemExit
    return iops_per_gb

def validate_volume_ids(volume_ids):
    if len(volume_ids) < 1:
        logger.error('At least one volume ID is required')
        raise SystemExit
    for volume_id in volume_ids:
        if volume_id == "":
            logger.error('Volume Id cannot be an empty string')
            raise SystemExit
    return volume_ids

def validate_empty_string(value):
    if value == "":
        raise argparse.ArgumentTypeError("Empty string is not allowed")
    return value

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Modifies an EBS volume to io2 and sets the IOPS')

    parser.add_argument('--aws_access_key_id', required=True, help='The AWS access key ID.', type=validate_empty_string)
    parser.add_argument('--aws_secret_access_key', required=True, help='The AWS secret access key.', type=validate_empty_string)
    parser.add_argument('--region_id', required=True, help='The AWS region id.', type=validate_empty_string)
    parser.add_argument('--iops_per_gb', default=500, help='The IOPS/GB to set for the volume. Contraints: Max IOPS/GB: 500 IOPS/GB, Max IOPS/Volume: 64,000, Max IOPS/Instance: 160,000', type=int)
    parser.add_argument('--volume_ids', required=True, nargs='+', help='The IDs of the EBS volumes to modify.')

    args = parser.parse_args()

    # Validate the arguments
    args.volume_ids = validate_volume_ids(args.volume_ids)
    args.iops_per_gb = validate_iops_per_gb(args.iops_per_gb)

    AWS_REGION_ID=args.region_id
    AWS_ACCESS_KEY_ID=args.aws_access_key_id
    AWS_SECRET_ACCESS_KEY=args.aws_secret_access_key

    migrateVol = MigrateVolume()

    try:
        migrateVol.modify_volumes_to_io2(args.volume_ids, args.iops_per_gb)
    except Exception as err:
        logger.error("Failed to migrate volume. Error: %s", str(err))
        raise err
