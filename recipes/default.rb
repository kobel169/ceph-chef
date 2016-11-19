#
# Author: Chris Jones <cjones303@bloomberg.net>
# Cookbook: ceph
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
#

include_recipe 'ceph-chef::repo' if node['ceph']['install_repo']
include_recipe 'ceph-chef::conf'

# Tools needed by cookbook
node['ceph']['packages'].each do |pck|
  package pck
end

chef_gem 'netaddr'


if node['ceph']['pools']['radosgw']['federated_enable']
  ceph_chef_build_federated_pool('radosgw')
end
