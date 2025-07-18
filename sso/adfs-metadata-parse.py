#!/usr/bin/python3
"""
Parses metadata from Microsoft AD FS and generates a Shibboleth attribute-map
for mapping SAML 2.0 & WS-Trust 1.3 scoped attributes to friendly names.
"""

import argparse
from lxml import etree
import sys
from urllib.parse import urlparse  # Python 3 change

# XPath to find IDPSSODescriptor element with attribute
# protocolSupportEnumeration equal to urn:oasis:names:tc:SAML:2.0:protocol
IDPSSO_XPATH = ''.join((
    '/*/saml2md:IDPSSODescriptor',
    "[@protocolSupportEnumeration='urn:oasis:names:tc:SAML:2.0:protocol']"
))

# XPath to find RoleDescriptor element with attribute
# protocolSupportEnumeration equal to
# http://docs.oasis-open.org/wsfed/federation/200706
WSFED_ROLEDESCRIPTOR_XPATH = (
    '/*/saml2md:RoleDescriptor'
    '[@protocolSupportEnumeration='
    "'http://docs.oasis-open.org/wsfed/federation/200706']"
)

ATTRIBUTE_MAP_NAMESPACE = 'urn:mace:shibboleth:2.0:attribute-map'
ATTRIB_NS = '{%s}' % ATTRIBUTE_MAP_NAMESPACE
NAMESPACES = {
    # WS-Federation
    'auth': 'http://docs.oasis-open.org/wsfed/authorization/200706',
    'fed': 'http://docs.oasis-open.org/wsfed/federation/200706',

    # SAML 2.0
    'saml2a': 'urn:oasis:names:tc:SAML:2.0:assertion',
    'saml2md': 'urn:oasis:names:tc:SAML:2.0:metadata',
}
NSMAP = {
    None: ATTRIBUTE_MAP_NAMESPACE,  # the default namespace (no prefix)
    'xsi': 'http://www.w3.org/2001/XMLSchema-instance'
}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('filename', help='Metadata file to update')
    parsed = parser.parse_args()
    if not parsed.filename:
        parser.print_usage()
        sys.exit(2)

    # Read metadata file
    metadata_file = parsed.filename
    metadata_xml = etree.parse(metadata_file)
    attributes = []

    # Find WS-Trust / SAML 1.0 attributes
    attributes.extend(
        metadata_xml.xpath(
            WSFED_ROLEDESCRIPTOR_XPATH +
            '/fed:ClaimTypesOffered/auth:ClaimType/attribute::Uri',
            namespaces=NAMESPACES)
    )

    # Find SAML 2.0 attributes
    attributes.extend(
        metadata_xml.xpath(
            IDPSSO_XPATH + '/saml2a:Attribute/attribute::Name',
            namespaces=NAMESPACES)
    )

    # Root element
    attr_map = etree.Element(ATTRIB_NS + 'Attributes', nsmap=NSMAP)

    for attribute in attributes:
        parsed_attribute = urlparse(attribute)
        path_parts = parsed_attribute.path.split('/')
        prefix = "{}://{}{}".format(
            parsed_attribute.scheme,
            parsed_attribute.netloc,
            '/'.join(path_parts[0:-1])
        )
        name = path_parts[-1]

        # SAML 2.0
        attribute_element = etree.SubElement(attr_map, 'Attribute')
        attribute_element.attrib.update({
            'id': name,
            'name': attribute,
            'nameFormat': 'urn:oasis:names:tc:SAML:2.0:attrname-format:unspecified'
        })
        etree.SubElement(
            attribute_element,
            'AttributeDecoder',
            attrib={
                'caseSensitive': 'false',
                '{' + NSMAP['xsi'] + '}type': 'StringAttributeDecoder'
            }
        )

        # SAML 1.0
        attribute_element = etree.SubElement(attr_map, 'Attribute')
        attribute_element.attrib.update({
            'id': name,
            'name': name,
            'nameFormat': prefix
        })
        etree.SubElement(
            attribute_element,
            'AttributeDecoder',
            attrib={
                'caseSensitive': 'false',
                '{' + NSMAP['xsi'] + '}type': 'StringAttributeDecoder'
            }
        )

    print(etree.tostring(attr_map, pretty_print=True).decode('utf-8'))


if __name__ == '__main__':
    main()
