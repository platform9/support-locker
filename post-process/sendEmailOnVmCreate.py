# Import all modules that we need to run this code
import requests, pickle, getpass, urllib, json, pprint, sys, smtplib, os.path
import crypto # This is actually crypto.py that must be in the same directory as this script.
from email.mime.text import MIMEText
from collections import namedtuple
from datetime import datetime, timedelta

def main():
  # Get current UTC time
  utcTime = datetime.utcnow()
  # The location where we will store the encrypted properties
  propertiesFile = 'encryptedProperties.pkl'

  # If the encrypted properties file doesn't exist, build the file
  if not (os.path.isfile(propertiesFile)):
    # Build a new object to store session information
    sessionInfo = {}
    # The next block of code asks for all of the info we need to run this script
    sessionInfo['identityApiEndpoint'] = raw_input('Keystone API URL:  ') 
    sessionInfo['osUsername'] = raw_input('OpenStack Username:  ')
    sessionInfo['osPassword'] = getpass.getpass('OpenStack Password:  ')
    sessionInfo['osTenant'] = raw_input('OpenStack Tenant:  ')
    sessionInfo['osRegion'] = raw_input(' OpenStack Region:  ')
    sessionInfo['checkInterval'] = raw_input('How far back do you want to check for events? In minutes: ')
    sessionInfo['eventType'] = raw_input('What type of OpenStack event are you looking to check for?  ')
    sessionInfo['fromAddress'] = raw_input('Which email address would you like to send these events from?  ')
    sessionInfo['toAddress'] = raw_input('Which email address would you like to send these events to?  ')
    sessionInfo['smtpServer'] = raw_input('SMTP Server hostname:  ')
    sessionInfo['smtpServerPort'] = raw_input('SMTP Server port:  ')
    sessionInfo['smtpUserName'] = raw_input('SMTP Username:  ')
    sessionInfo['smtpPassword'] = getpass.getpass('SMTP Password:  ')

    # Convert the properties to a json string and encrypt them
    encryptProperties = crypto.crypt(str(json.dumps(sessionInfo)), 'encrypt', '') 
    # Open the file we will store the encrypted properties in
    with open(propertiesFile, 'wb') as output:
      # Write the encrypted properties to the file
      pickle.dump(encryptProperties, output, pickle.HIGHEST_PROTOCOL)

  # If the encrypted properties file does exist decypt them
  else:
    # Open the file we stored teh encrypted properties in
    with open(propertiesFile, 'rb') as input:
      # Retrieve Encrypted Properties
      encryptedProperties = pickle.load(input)
    # Decrypt the encrypted properties
    decryptedProperties = crypto.crypt(encryptedProperties['string'], 'decrypt', encryptedProperties['secret'])
    # Load the decrypted properties into sessionInfo
    sessionInfo = json.loads(decryptedProperties['string'])

  # JSON that gets created to authenticate to Keystone
  authData = '{"auth": {"tenantName": "%s","passwordCredentials": {"username": "%s", "password": "%s"}}}' % (sessionInfo['osTenant'], sessionInfo['osUsername'], sessionInfo['osPassword'])
  # Header we will use for teh RestAPI call
  authHeaders = {'Content-type': 'application/json'}

  # Make the RestAPI call to authenticate to Keystone
  authReq = requests.post('%s/tokens' % sessionInfo['identityApiEndpoint'], data=authData, headers=authHeaders)
  if not (authReq.status_code == requests.codes.ok): 
    print "%s Something went wrong with authenticating to Keystone" % datetime.utcnow()
    print "%s Status Code:  %s" % (datetime.utcnow(), authReq.status_code)
    print "%s Response Text: %s" % (datetime.utcnow(), authReq.text)
    sys.exit()

  # Store the JSON from the RestAPI call
  osToken = authReq.json()
  # Pull the authentication token from the RestAPI JSON
  xAuthToken = osToken['access']['token']['id']

  # Create a new object to store service info
  services = {}
  # Loop through the service catalog
  for svc in osToken['access']['serviceCatalog']:
    # The next four lines stores service details into the service object using the service type as the key.
    service = {}
    service['name'] = svc['name']
    for endpoint in svc['endpoints']:
      if (endpoint['region'] == sessionInfo['osRegion']):
        service['url'] = endpoint['publicURL']
    services[svc['type']] = service

  # Header we will use to authenticate to other API Endpoints
  tokenHeaders = {'X-Auth-Token': xAuthToken}
  # Get the current UTC date and time (Minus the CheckInterval in minutes), format it correctly for the query, and URL Encode.
  urlDate = urllib.quote((utcTime - timedelta(minutes=int(sessionInfo['checkInterval']))).strftime('%Y-%m-%dT%H:%M:%S'))
  # Build the event query we will use to only return the events we want.
  eventQuery = '?q.field=start_time&q.field=event_type&q.op=gt&q.op=eq&q.type=&q.type=&q.value=%s&q.value=%s' % (urlDate, sessionInfo['eventType'])

  # Make a RestAPI call to Ceilometer using the query and headers from above
  eventsReq = requests.get('%s/v2/events%s' % (services['metering']['url'], eventQuery), headers=tokenHeaders)
  # Store the JSON from the RestAPI call
  events = eventsReq.json()

  # Create a new Array for the events found by Ceilometer
  newEvents = []
  # Loop through each event that is found
  for event in events:
    # The next six lines will build a new object with all of the info that is found from the event
    ceilometerEvent = {}
    ceilometerEvent['generated'] = event['generated']
    ceilometerEvent['message_id'] = event['message_id']
    ceilometerEvent['event_type'] = event['event_type']
    # Loop through each trait of the event and add them to the new object as well
    for trait in event['traits']:
      ceilometerEvent[trait['name']] = trait['value']
    # Push the new event object into the array we created previously
    newEvents.append(ceilometerEvent)

  # Now that I have a clean object to work with. I'm going to loop through them
  for event in newEvents:
    # Query the compute API and pull all in more information about the instace that was created
    compReq = requests.get('%s/servers/%s' % (services['compute']['url'], event['instance_id']), headers=tokenHeaders)
    # Build an email body that contians both the ceilometer data as well as the nova data for the VM that was created.
    emailBody = 'Ceilometer Info:'
    emailBody += '\n\n'
    emailBody += str(json.dumps(event, indent=3))
    emailBody += '\n\n\n\n'
    emailBody += 'Instance Info:'
    emailBody += '\n\n'
    emailBody += str(json.dumps(compReq.json(), indent=3))
    emailBody += '\n\n\n\n'
    emailBody += 'Have a great day!'
    emailBody += '\n'
    emailBody += 'Platform9'
    # Create an email subject that contains the instacne name.
    emailSubject = 'A new instance has been created:  %s' % event['name']
    # Add the message body to the message object
    msg = MIMEText(emailBody)
    # Add the Subject to the message object
    msg['Subject'] = emailSubject
    # Add the from address to the message object
    msg['From'] = sessionInfo['fromAddress']
    # Add the to address to the message object
    msg['To'] = sessionInfo['toAddress']
    # Configure your SMTP server
    s = smtplib.SMTP('%s:%s' % (sessionInfo['smtpServer'], sessionInfo['smtpServerPort']))
    # The next five lines sends connects to the smtp server creates a secure channel and sends the email.
    s.ehlo()
    s.starttls()
    s.login(sessionInfo['smtpUserName'], sessionInfo['smtpPassword'])
    s.sendmail(sessionInfo['fromAddress'], sessionInfo['toAddress'], msg.as_string())
    s.quit()

  eventCount = len(newEvents)
  print "%s The script ran succesfully and found %d new events" % (datetime.utcnow(), eventCount)

if __name__ == "__main__": main()
