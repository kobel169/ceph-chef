#
# Author:: Chris Jones <cjones303@bloomberg.net>
# Cookbook Name:: ceph
# Recipe:: osd
#
# Copyright 2016, Bloomberg Finance L.P.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# NOTE: Example of an OSD device to add. You can find other examples in the OSD attribute file and the
# environment file. The device and the journal should be the same IF you wish the data and journal to be
# on the same device (ceph default). However, if you wish to have the data on device by itself (i.e., HDD)
# and the journal on a different device (i.e., SSD) then give the cooresponding device name for the given
# entry (device or journal). The command 'ceph-disk prepare' will keep track of partitions for journals
# so DO NOT create a device with partitions already configured and then attempt to use that as the journal:
# device value. Journals are raw devices (no file system like xfs).
#
# "osd": {
#    "devices": [
#        {
#            "type": "hdd",
#            "data": "/dev/sdb",
#            "data_type": "hdd",
#            "journal": "/dev/sdf",
#            "journal_type": "ssd",
#            "encrypted": false,
#            "status": ""
#        }
#    ]
# }

# Standard Ceph UUIDs:
# NOTE: Ceph OSD uuid type 4fbd7e29-9d25-41b8-afd0-062c0ceff05d
# NOTE: dmcrypt Ceph OSD uuid type 4fbd7e29-9d25-41b8-afd0-5ec00ceff05d
# NOTE: Ceph Journal uuid type 45b0969e-9b03-4f30-b4c6-b4b80ceff106
# NOTE: dmcrypt Ceph Journal uuid type 45b0969e-9b03-4f30-b4c6-5ec00ceff106

include_recipe 'ceph-chef'
include_recipe 'ceph-chef::osd_install'

# Disk utilities used
package 'gdisk' do
  action :upgrade
end

package 'cryptsetup' do
  action :upgrade
  only_if { node['ceph']['osd']['dmcrypt'] }
end

# Create the scripts directory within the /etc/ceph directory. This is not standard Ceph. It's included here as
# a place to hold helper scripts mainly for OSD and Journal maintenance
directory '/etc/ceph/scripts' do
  mode node['ceph']['mode']
  recursive true
  action :create
  not_if 'test -d /etc/ceph/scripts'
end

# Add ceph_journal.sh helper script to all OSD nodes and place it in /etc/ceph
cookbook_file '/etc/ceph/scripts/ceph_journal.sh' do
  source 'ceph_journal.sh'
  mode node['ceph']['mode']
  not_if 'test -f /etc/ceph/scripts/ceph_journal.sh'
end

if node['ceph']['version'] == 'hammer'
  directory '/var/lib/ceph/bootstrap-osd' do
    owner node['ceph']['owner']
    group node['ceph']['group']
    mode node['ceph']['mode']
    recursive true
    action :create
    not_if 'test -d /var/lib/ceph/bootstrap-osd'
  end

  # Default data location - do not modify
  directory '/var/lib/ceph/osd' do
    owner node['ceph']['owner']
    group node['ceph']['group']
    mode node['ceph']['mode']
    recursive true
    action :create
    not_if 'test -d /var/lib/ceph/osd'
  end
end

execute 'osd-create-key-mon-client-in-directory' do
  command lazy { "ceph-authtool /etc/ceph/#{node['ceph']['cluster']}.mon.keyring --create-keyring --name=mon. --add-key=#{ceph_chef_mon_secret} --cap mon 'allow *'" }
  not_if "test -f /etc/ceph/#{node['ceph']['cluster']}.mon.keyring"
end

execute 'osd-create-key-admin-client-in-directory' do
  command lazy { "ceph-authtool /etc/ceph/#{node['ceph']['cluster']}.client.admin.keyring --create-keyring --name=client.admin --add-key=#{ceph_chef_admin_secret} --cap mon 'allow *' --cap osd 'allow *' --cap mds 'allow *'" }
  not_if "test -f /etc/ceph/#{node['ceph']['cluster']}.client.admin.keyring"
end

# Verifies or sets the correct mode only
file "/etc/ceph/#{node['ceph']['cluster']}.client.admin.keyring" do
  mode '0644'
end

execute 'osd-create-key-bootstrap-in-directory' do
  command lazy { "ceph-authtool /var/lib/ceph/bootstrap-osd/#{node['ceph']['cluster']}.keyring --create-keyring --name=client.bootstrap-osd --add-key=#{ceph_chef_bootstrap_osd_secret}" }
  # NOTE: If the keyring exists then skip even if the node['bootstrap-osd'] ('ceph_chef_bootstrap_osd_secret') is not empty because you can also copy from other osd node or a central place where may keep keyring files. Just depends on your environment.
  not_if "test -f /var/lib/ceph/bootstrap-osd/#{node['ceph']['cluster']}.keyring"
  only_if { ceph_chef_bootstrap_osd_secret }
end

# BOOTSTRAP_KEY=`ceph --name mon. --keyring '/etc/ceph/#{node['ceph']['cluster']}.mon.keyring' auth get-or-create-key client.bootstrap-osd mon 'allow profile bootstrap-osd'`
bash 'osd-write-bootstrap-osd-key' do
  code <<-EOH
    BOOTSTRAP_KEY=$(ceph-authtool "/etc/ceph/#{node['ceph']['cluster']}.mon.keyring" -n mon. -p)
    ceph-authtool "/var/lib/ceph/bootstrap-osd/#{node['ceph']['cluster']}.keyring" \
        --create-keyring \
        --name=client.bootstrap-osd \
        --add-key="$BOOTSTRAP_KEY"
  EOH
  # NOTE: If the keyring exists then skip even if the node['bootstrap-osd'] ('ceph_chef_bootstrap_osd_secret') is empty because you can also copy from other osd node or a central place where may keep keyring files. Just depends on your environment.
  not_if "test -f /var/lib/ceph/bootstrap-osd/#{node['ceph']['cluster']}.keyring"
  not_if { ceph_chef_bootstrap_osd_secret }
  notifies :create, 'ruby_block[save_bootstrap_osd_key]', :immediately
end

# Blocks like this are used in many places so as to save the values that are generated from bash commands like the one
# above. The saved value may be used later in other recipes.
ruby_block 'save_bootstrap_osd_key' do
  block do
    fetch = Mixlib::ShellOut.new("ceph-authtool /var/lib/ceph/bootstrap-osd/#{node['ceph']['cluster']}.keyring --print-key")
    fetch.run_command
    key = fetch.stdout
    ceph_chef_save_bootstrap_osd_secret(key.delete!("\n"))
  end
  action :nothing
end

# Calling ceph-disk prepare is sufficient for deploying an OSD
# After ceph-disk prepare finishes, the new device will be caught
# by udev which will run ceph-disk-activate on it (udev will map
# the devices if dm-crypt is used).
# IMPORTANT:
#  - Always use the default path for OSD (i.e. /var/lib/ceph/osd/$cluster-$id)
if node['ceph']['osd']['devices']
  devices = node['ceph']['osd']['devices']

  devices = Hash[(0...devices.size).zip devices] unless devices.is_a? Hash

  devices.each do |index, osd_device|
    # Only one partition by default for ceph data
    partitions = 1

    if !node['ceph']['osd']['devices'][index]['status'].nil? && node['ceph']['osd']['devices'][index]['status'] == 'deployed'
      Log.info("osd: osd device '#{osd_device}' has already been setup.")
      next
    end

    # if the 'encrypted' attribute is true then apply flag. This will encrypt the data at rest.
    # IMPORTANT: More work needs to be done on solid key management for very high security environments.
    dmcrypt = osd_device['encrypted'] == true ? '--dmcrypt' : ''

    # is_device - Is the device a partition or not
    # is_ceph - Does the device contain the default 'ceph data' or 'ceph journal' label
    # The -v option is added to the ceph-disk script so as to get a verbose output if debugging is needed. No other reason.
    # is_ceph=$(parted --script #{osd_device['data']} print | egrep -sq '^ 1.*ceph')

    execute "ceph-disk-prepare on #{osd_device['data']}" do
      command <<-EOH
        id='#{node.name[-1].to_i - 1}'
        is_device=$(echo '#{osd_device['data']}'$id | egrep '/dev/(([a-z]{3,4}[0-9]$)|(cciss/c[0-9]{1}d[0-9]{1}p[0-9]$))')
        ceph-disk -v prepare --cluster #{node['ceph']['cluster']} #{dmcrypt} --fs-type #{node['ceph']['osd']['fs_type']} #{osd_device['data']}$id || exit 1
#        ceph-osd -i $id --mkfs --mkkey || exit 1
        cp /etc/ceph/ceph.osd.$id.keyring /var/lib/ceph/osd/ceph-$id/keyring || exit 1
#        ceph auth add osd.$id osd 'allow *' mon 'allow rwx' -i /var/lib/ceph/osd/ceph-$id/keyring
        ceph-disk -v activate #{osd_device['data']}$id/ || exit 1
        sleep 3

      EOH
      # NOTE: The meaning of the uuids used here are listed above
      not_if "sgdisk -i1 #{osd_device['data']} | grep -i 4fbd7e29-9d25-41b8-afd0-062c0ceff05d" unless dmcrypt
      not_if "sgdisk -i1 #{osd_device['data']} | grep -i 4fbd7e29-9d25-41b8-afd0-5ec00ceff05d" if dmcrypt
      # Only if there is no 'ceph *' found in the label. The recipe os_remove_zap should be called to remove/zap
      # all devices if you are wanting to add all of the devices again (if this is not the initial setup)
      not_if "parted --script #{osd_device['data']} print | egrep -sq '^ 1.*ceph'"
      action :run
      notifies :create, "ruby_block[save osd_device status #{index}]", :immediately
    end

    # Add this status to the node env so that we can implement recreate and/or delete functionalities in the future.
    ruby_block "save osd_device status #{index}" do
      block do
        node.normal['ceph']['osd']['devices'][index]['status'] = 'deployed'
        node.save
      end
      action :nothing
      # only_if "ceph-disk list 2>/dev/null | grep 'ceph data' | grep #{osd_device['data']}"
    end

    # NOTE: Do not attempt to change the 'ceph journal' label on a partition. If you do then ceph-disk will not
    # work correctly since it looks for 'ceph journal'. If you want to know what Journal is mapped to what OSD
    # then do: (cli below will output the map for you - you must be on an OSD node)
    # ceph-disk list
  end
else
  Log.info("node['ceph']['osd']['devices'] empty")
end
