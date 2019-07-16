# -*- mode: ruby -*-
# vi: set ft=ruby :

Vagrant.configure(2) do |config|
  $num_instances = 1
  (1..$num_instances).each do |i|
    config.vm.define vm_name = "centos-7-%02d.vagrant.test"  % [i] do |config|

    config.vm.box = "centos/7"

    ip = "192.168.33.#{i+6}"

    config.vm.network :private_network, ip: ip
      config.vm.provider "virtualbox" do |vb|
        config.vm.synced_folder "../", "/vagrant", type: "rsync", rsync__args: ["--verbose", "--archive", "--delete", "-z"]
        vb.memory = "1000"
        vb.cpus = "1"
      end
      config.vm.provision "shell" do |s|
        ssh_pub_key = File.readlines("#{Dir.home}/.ssh/id_rsa.pub").first.strip
        s.inline = <<-SHELL
          yum install -y policycoreutils policycoreutils-python selinux-policy selinux-policy-targeted libselinux-utils setools setools-console
          setenforce 1
        SHELL
      end
     end
  end
end
