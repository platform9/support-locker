def crypt (stringToCrypt, action, secret):
  # This code was found (and tweaked very little by myslef) here: https://gist.github.com/sekondus/4322469
  from Crypto.Cipher import AES 
  import base64
  import os

  # the block size for the cipher object; must be 16, 24, or 32 for AES
  BLOCK_SIZE = 32

  # the character used for padding--with a block cipher such as AES, the value
  # you encrypt must be a multiple of BLOCK_SIZE in length. This character is
  # used to ensure that your value is always a multiple of BLOCK_SIZE
  PADDING = '{' 

  # one-liner to sufficiently pad the text to be encrypted
  pad = lambda s: s + (BLOCK_SIZE - len(s) % BLOCK_SIZE) * PADDING

  # one-liners to encrypt/encode and decrypt/decode a string
  # encrypt with AES, encode with base64
  EncodeAES = lambda c, s: base64.b64encode(c.encrypt(pad(s)))
  DecodeAES = lambda c, e: c.decrypt(base64.b64decode(e)).rstrip(PADDING)

  # generate a random secret key
  if not (secret): secret = os.urandom(BLOCK_SIZE)
  else: secret = base64.b64decode(secret)

  # create a cipher object using the random secret
  cipher = AES.new(secret)

  if (action == 'encrypt'):
    # encode a string
    encrypt = {}
    encrypt['string'] = EncodeAES(cipher, stringToCrypt)
    encrypt['secret'] = base64.b64encode(secret)
    return encrypt
  elif (action == 'decrypt'):
    # decode the encoded string
    decrypt = {}
    decrypt['string'] = DecodeAES(cipher, stringToCrypt)
    decrypt['secret'] = secret
    return decrypt
  else:
    print 'Function: crypt only supports actions of "encrypt" and "decrypt":  "%s" is invalid' % action
