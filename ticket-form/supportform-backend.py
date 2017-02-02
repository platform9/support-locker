import json
import base64
import requests
import re
from flask import request
from flask import current_app

def create_ticket(subject, body, priority="low", requester_name='', requester_email='', collaborators=[]):
  EMAIL_REGEX=r"(^[a-zA-Z0-9_.+-]+@[a-zA-Z0-9-]+\.[a-zA-Z0-9-.]+$)"

  # Validate CC emails
  ccs = []
  for collaborator in collaborators:
    if re.match(EMAIL_REGEX, collaborator):
      ccs.append(collaborator)
    else:
      current_app.logger.warning("PF9-Ticket collaborator: Invalid Email: '%s' This CC will be ignored." % collaborator)
  # Validate requester_email
  if not re.match(EMAIL_REGEX, requester_email):
    # Error: invalid email
    # Only log these for now, later we will ship logs like this out to the admin so we can debug and fix the issue
    current_app.logger.error("Invalid Requester Email specified. User submitted: %s\nThis ticket cannot be sumitted without a valid email" % requester_email)
    raise ValueError('Invalid Requester Email was specified. Please enter a valid email')

  # Example Ticket JSON
  payload = { "ticket": { "subject": subject, "priority": priority, "collaborators": ccs, "comment": { "body": body, "public": True } } }

  # Requester Information
  payload ['ticket']['requester'] = { "email": requester_email, "name": requester_name, "locale_id": 1 }

  return payload

# Submits the request to Zendesk API
def zendesk (url, payload=None):
  #LOG.info ("URL %s" % url)

  data = None

  username = 'support-notify@platform9.com'
  zendesk_token = 'enterthevalidtokenhere'
  username_mit_token = str.encode(username + '/token:' + zendesk_token)

  base64string = base64.encodestring(username_mit_token).replace(b'\n', b'').decode("utf-8")
  headers = { "Authorization": "Basic %s" % base64string, "Content-Type": "application/json" }

  current_app.logger.info("URL %s \n header %s \n data %s" % (url, headers, json.dumps(payload)))
  current_app.logger.info("PF9-Ticket Submit to Zendesk: %s" % json.dumps(payload))
  
  req = requests.post(url, headers=headers, data=json.dumps(payload))

  return req.json()

def main():
  # Zendesk API Endpoint: Create Ticket
  url = 'https://platform9.zendesk.com/api/v2/tickets'

  data = []
  data = json.loads(request.get_data().decode("utf-8"))
  current_app.logger.info("PF9-Ticket Payload: %s" % data)
  ### Placeholder Variables
  # affected component(s)
  components = []
  # default scope and severity is lowest
  severity = 4
  affected = 'none'
  zendesk_severity = 'low'
  # requester info
  rname = ''
  remail = ''
  organization = ''
  collabs = ''
  # ticket info
  subject = ''
  body = ''

  if not data:
    return("Error: no data provided")
  # Iterate throught the request body
  for field in data:

    name = field['name']
    value = field['value']

    if (name == 'full_name'):
      rname = value
      continue
    if (name == 'email'):
      remail = value
      continue
    if (name == 'title'):
      subject = value
      continue
    if (name == 'description'):
      body = value
      continue
    if (name == 'organization'):
      organization = value
      continue

    # Combine PF9 components into list
    if (name == 'component') | (name == 'component-other'):
      components.append(value)
      continue

    # Severity and Scope
    if (name == 'severity'):
      severity = int(value)
      continue
    if (name == 'scope'):
      affected = value
      continue

    if (name == 'ccs'):
      collabs = [x.strip() for x in value.split(',')]
      continue

  # Prioritize the ticket
  if severity == 0:
    if affected == 'none':
      zendesk_severity = 'high'
    elif affected == 'some':
      zendesk_severity = 'urgent'
    elif affected == 'all':
      zendesk_severity = 'urgent'
  elif severity == 1:
    if affected == 'none':
      zendesk_severity = 'high'
    elif affected == 'some':
      zendesk_severity = 'high'
    elif affected == 'all':
      zendesk_severity = 'high'
  elif severity == 2:
    if affected == 'none':
      zendesk_severity = 'medium'
    elif affected == 'some':
      zendesk_severity = 'medium'
    elif affected == 'all':
      zendesk_severity = 'high'
  elif severity == 3:
    if affected == 'none':
      zendesk_severity = 'low'
    elif affected == 'some':
      zendesk_severity = 'low'
    elif affected == 'all':
      zendesk_severity = 'medium'
  else:
    zendesk_severity = 'low'

  components = ", ".join(components)

  body = "organization: %s\nComponents: %s\n\n%s" % (organization, components, body)
  payload = create_ticket(subject, body, zendesk_severity, rname, remail, collabs)
  #return ("Payload: %s" % payload)

  result = zendesk (url, payload=payload)
  return(json.dumps(result))

