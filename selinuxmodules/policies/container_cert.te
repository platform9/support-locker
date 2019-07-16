module container_cert 1.0;

require {
  type container_t;
  type cert_t;
  class file { open read };
  class dir { read };
  class lnk_file { read };
}

allow container_t cert_t:file { open read };
allow container_t cert_t:lnk_file { read };
allow container_t cert_t:dir { read };
